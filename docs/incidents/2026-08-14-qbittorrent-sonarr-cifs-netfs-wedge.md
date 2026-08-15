# Incident: qBittorrent-Sonarr CIFS/netfs kernel wedge

## Document status

- Incident date: 2026-08-14
- Host timezone: America/Chicago (CDT)
- Affected service: `qbittorrent-sonarr`
- Related services: `proton-wg@sonarr`, `proton-port-forward@sonarr`, `proton-docker-watch@sonarr`, `proton-healthcheck@sonarr`
- Severity: service outage with host reboot required for complete recovery
- Investigation status: root cause established to the host-kernel/CIFS boundary; exact upstream defect is a strong signature match, not proven identity
- Recovery status at documentation time: persistent fixes prepared; the unreapable kernel task remains until an approved host reboot

## Executive summary

`qbittorrent-sonarr` became impossible for Docker to stop or recreate because a qBittorrent worker faulted inside the Linux `netfs`/CIFS buffered-read path. The kernel oops killed one execution context while another qBittorrent thread remained blocked in uninterruptible `D` state, waiting in `folio_wait_bit_common`. The qBittorrent process leader later became a zombie.

Docker delivered `SIGTERM`, waited the configured 90-second grace period, escalated to `SIGKILL`, and then attempted a direct kill. None of those actions could complete the container lifecycle because signals cannot release a thread sleeping uninterruptibly inside kernel I/O. Docker consequently retained the old container identity while portions of its namespaces had already disappeared. Health checks then failed before `curl` could run.

This was not a Web UI failure, ordinary qBittorrent deadlock, stale lockfile, memory exhaustion, or Docker restart-policy problem. The immediate recovery boundary is the host kernel. A host reboot is required.

Three independent automation defects would have prevented clean service recovery even after the kernel task disappeared:

1. Sonarr's Proton WireGuard unit had been failed since 2026-08-09 after concurrent instances raced while replacing shared policy-routing rules and one received `RTNETLINK answers: File exists`.
2. The qBittorrent allocator systemd unit executed a non-executable script from the source checkout and failed with systemd `203/EXEC`.
3. The managed port artifact stored the same port under both `QBT_PUBLISHED_PORT` and the unused `QBT_FORWARDED_PORT`, creating two supposed sources of truth.

The corrective implementation serializes all shared route mutations, installs every systemd executable from `/usr/local/bin/proton`, reduces the port artifact to one assignment, adds a kernel `D`-state guard, centralizes Compose policy for all five qBittorrent services, and adds fleet-wide verification and rolling reconciliation tools.

## Impact

### User-visible impact

- `qbittorrent-sonarr` remained `Up` according to Docker but was unhealthy and unusable.
- The Web UI on port `8084` could not be entered through a Docker health-check exec.
- Sonarr torrent activity could not progress normally.
- Docker Compose could not safely replace the named container.
- Repeated recreation attempts risked orphan containers and Docker name conflicts without repairing the kernel task.

### Scope

The observed wedge was limited to `qbittorrent-sonarr`, but the underlying storage exposure is fleet-wide. All five qBittorrent services mount `/mnt/data:/data` and use the CIFS-backed tree for incomplete torrent data. Therefore kernel and storage mitigations must be evaluated for:

- `qbittorrent-lidarr`
- `qbittorrent-prowlarr`
- `qbittorrent-radarr`
- `qbittorrent-sonarr`
- `qbittorrent-whisparr`

The dynamic Proton leases, tunnel interfaces, route tables, credentials, and container identities remain independent. Fleet-wide mitigation does not mean copying one instance's port to the others.

## Environment at failure

- Kernel: Ubuntu `7.0.0-29-generic`, package revision `7.0.0-29.29`
- Container image: `lscr.io/linuxserver/qbittorrent:libtorrentv1`
- Docker service: `qbittorrent-sonarr`
- Web UI port: `8084`
- Published torrent port at the time of the wedge: TCP and UDP `51055`
- Tunnel bind address: `10.4.0.2`
- Docker network: external `starr_network`
- Data mount: `/mnt/data` backed by `//192.168.237.140/data`
- CIFS options observed during investigation: SMB 3.1.1, `cache=strict`, `soft`
- Filesystem utilization observed: approximately 97%; this is context, not a demonstrated cause

The qBittorrent config volume under `/opt/qbittorrent-sonarr/config` is local ext4. The blocked file was on the CIFS-backed data volume, not the local config volume.

## Exact I/O target

The blocked qBittorrent thread held two file descriptors to this incomplete torrent file:

```text
/data/downloads/torrents/incomplete/Breaking.Bad.S01-S05.REPACK.COMPLETE.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1-FraMeSToR/Breaking.Bad.S02E12.Phoenix.REPACK2.1080p.DTS-HD.MA.5.1.AVC.REMUX-FraMeSToR.mkv
```

Inside the container, `/data` maps to host `/mnt/data`. The path identifies the operation that was in progress; it does not prove that the media file itself is corrupt. Do not delete it solely because it appears in the blocked descriptors. After recovery, use qBittorrent's force-recheck and inspect storage/kernel logs before deciding whether any payload is damaged.

## Timeline

### Earlier Proton failure

- 2026-08-09 11:10:12: Proton instance services stopped during the preceding reboot sequence.
- 2026-08-09 11:11:12: the prior Sonarr WireGuard stop exceeded its timeout.
- 2026-08-09 11:12:53: five templated WireGuard instances started concurrently.
- 2026-08-09 11:12:55: Sonarr created `pvsonarr`, configured its address/DNS/kill-switch path, then failed with `RTNETLINK answers: File exists` while shared policy rules were being replaced.
- The dependent Sonarr port-forward, Docker watcher, and healthcheck units remained inactive afterward.
- Sonarr's last observed Proton allocation during that startup was `54105`; it was not a live, continuously refreshed lease by August 14.

### Kernel failure and Docker wedge

- 2026-08-14 11:51:57: kernel NULL-pointer dereference in a `qbittorrent-nox` context.
- The call trace entered `netfs_read_gaps`, `netfs_read_folio`, `filemap_read_folio`, `cifs_strict_readv`, `vfs_readv`, and `do_preadv`.
- A surviving qBittorrent thread remained in `D` state with wait channel `folio_wait_bit_common`.
- 2026-08-14 22:41:43: attempted allocator units for other instances failed with `203/EXEC` because their entrypoint was mode `0664` and referenced the source tree.
- 2026-08-14 22:45:05: Docker began stopping `qbittorrent-sonarr`. qBittorrent logged that termination was initiated, resume data was saved, and it was exiting cleanly.
- 2026-08-14 22:46:35: Docker's 90-second grace period expired.
- 2026-08-14 22:46:45: Docker's additional direct `SIGKILL` attempt also failed.
- 2026-08-14 22:46:49: Docker reported that it tried to kill the container but did not receive an exit event.
- Subsequent health checks failed with a runtime error opening `/proc/1619791/ns/ipc`, showing that namespace teardown was already partial.

## Evidence

### Kernel call trace

The decisive evidence was the local kernel trace:

```text
BUG: kernel NULL pointer dereference, address 0000000000000008
CPU: 13 PID: 2908428 Comm: qbittorrent-nox
RIP: netfs_read_gaps+0x3f/0x4b0 [netfs]

Call Trace:
  netfs_read_folio
  filemap_read_folio
  ...
  cifs_strict_readv
  vfs_readv
  do_preadv
  __x64_sys_preadv
```

The trace also noted that the qBittorrent task exited with interrupts disabled. That is a kernel failure, not an application-generated error.

### Process state

Investigation found:

- container init PID `1619791` (`s6-svscan`) still present;
- qBittorrent leader PID `1620095` in zombie state;
- qBittorrent thread/TID `2899237` in `Dsl` state;
- wait channel `folio_wait_bit_common`;
- approximately 2 GiB resident memory and 773 MiB swap for the surviving thread context;
- the container cgroup still populated;
- `SIGKILL` pending but unable to complete while the kernel wait remained.

### Docker state

Docker reported:

- state `running`;
- health `unhealthy`;
- no OOM kill;
- restart count `0`;
- TCP and UDP port `51055` still published on `10.4.0.2`;
- exec/health-check failure at namespace entry rather than an HTTP response.

The retained published ports matter: a wedge cannot be identified only by “running with no ports.” Zombie and `D`-state detection are both required.

## Root-cause assessment

### Confirmed primary cause

The primary cause was a Linux kernel fault in the CIFS/netfs buffered-read path while qBittorrent accessed the mounted data share. The remaining uninterruptible folio wait made normal Docker lifecycle operations incapable of reaping the container.

### Strong signature match

The trace strongly matches the failure mode described by CVE-2026-64064, in which `netfs_read_gaps()` can dereference absent per-folio state after a truncation-related path. References:

- Ubuntu security record: <https://ubuntu.com/security/CVE-2026-64064>
- Linux kernel CVE record: <https://kernel.googlesource.com/pub/scm/linux/security/vulns/+/532b7a5822a5879693dafb0e357333cf92f8271b/cve/published/2026/CVE-2026-64064.mbox>

This incident must not be labeled definitively as CVE-2026-64064 without kernel-maintainer confirmation. Ubuntu reports the issue fixed in a version older than the installed `7.0.0-29` kernel. Reproduction on `7.0.0-29` therefore suggests an incomplete backport, a regression, or a related uncovered path.

### Contributing automation cause: route race

Every instance's `proton-wg-up-safe.sh` performed this shared-policy pattern without a global lock:

```text
delete shared priority-108 rule
add shared priority-108 rule
delete shared priority-109 rule
add shared priority-109 rule
```

Five concurrent starts could interleave as follows:

```text
Sonarr: delete rule
Lidarr: delete rule (already absent; ignored)
Lidarr: add rule
Sonarr: add rule -> EEXIST -> set -e abort
```

The exact boot timing and `RTNETLINK answers: File exists` support this mechanism. The route mutation paths are now serialized through one global `/run/proton/policy-routing.lock` shared by WireGuard up, WireGuard down, and Docker watcher reconciliation.

### Contributing automation cause: allocator deployment

`proton-qbt-allocate@.service` directly executed:

```text
/usr/local/bin/proton_project/proton-qbt-allocate-and-sync.sh
```

That source file was not executable and neither the script nor unit was part of the installer. The repaired design installs the script as root-owned mode `0755` under `/usr/local/bin/proton`, installs the unit, validates the instance name, and points the unit only at the installed path.

### Contributing configuration cause: duplicate port alias

The persistent artifact contained:

```dotenv
QBT_PUBLISHED_PORT=<port>
QBT_FORWARDED_PORT=<same-port>
```

No production consumer used `QBT_FORWARDED_PORT`; only a test required it. It has been removed. The artifact is written atomically and must contain exactly one assignment:

```dotenv
QBT_PUBLISHED_PORT=<port>
```

## Why ordinary recovery did not work

### Why qBittorrent could say “Exiting cleanly” while remaining present

The application leader completed much of its shutdown, including resume-data persistence. A different thread remained blocked inside kernel I/O. Process-level shutdown logging cannot guarantee that every thread has returned from the kernel.

### Why SIGKILL did not work

`SIGKILL` is acted upon when a task returns to a state in which the kernel can deliver and process the signal. A task in uninterruptible `D` state is deliberately not interruptible. If the wait will never complete because the kernel state was damaged by an oops, the signal remains pending indefinitely.

### Why Docker restart, remove, or Compose recreation did not work

All those operations eventually depend on the old container tasks exiting and the runtime receiving an exit event. Docker cannot safely create a replacement under the same name while the old container still owns it. Repeated attempts can produce orphans and name conflicts without changing the blocked kernel state.

### Why killing `containerd-shim` is not the recovery for this branch

Killing a shim can sometimes repair a userspace bookkeeping wedge after all container processes are killable. It cannot release a host task blocked in kernel `D` state. Doing so here discards runtime supervision while leaving the kernel task and mount references behind. The runbook therefore treats confirmed `D` state plus a netfs/CIFS oops as a hard stop and requires a host reboot.

## Corrective changes

The implemented changes are fleet-wide:

1. One shared Compose service policy is deployed at `/opt/qbittorrent-common/docker-compose.common.yml`.
2. All five instance Compose files extend that policy and contain only documented instance differences.
3. A canonical instance manifest defines Web UI port, legacy port reference, bind IP, full interface name, address subnet, route table, and rule priority; live Compose requires an explicitly injected Proton port and has no port or `0.0.0.0` fallback.
4. Project `.env` files remain static and contain only `QBT_HOST_BIND_IP`.
5. Per-instance port artifacts contain only `QBT_PUBLISHED_PORT` and are written atomically.
6. The sync script refuses to use a project `.env` as its dynamic port artifact.
7. The sync script validates ports in the range 1–65535.
8. The sync script detects zombie and uninterruptible `D`-state conditions before Compose recreation.
9. WireGuard up/down and Docker watcher route changes use one global route lock.
10. Both nftables and iptables kill-switch backends use one host-wide kill-switch lock.
11. The allocator script and unit are installed through the canonical deployment path.
12. The generated Docker network name is corrected to `starr_network`.
13. Full live interface names `pvprowlarr` and `pvwhisparr` replace shortened stale examples.
14. Static, protected-config, and runtime fleet verifiers enforce parity.
15. A rolling reconciler can force all five containers through the same shared structural change while preserving each instance's own Proton lease.

## Recovery still required

The code/configuration fixes cannot reap the already blocked kernel task. Complete operational recovery still requires:

1. capture any final evidence needed for an Ubuntu/kernel report;
2. obtain approval for a host-wide maintenance reboot;
3. reboot the host;
4. verify `/mnt/data` is mounted at the intended leaf path and is writable before qBittorrent resumes;
5. verify the running kernel and record its package revision;
6. start/reconcile Proton instances sequentially;
7. run one allocator/sync transaction for every instance;
8. verify the complete fleet contract;
9. force-recheck the affected torrent;
10. monitor for renewed `netfs`, CIFS, folio, `D`-state, or Docker kill-timeout symptoms.

Use the detailed procedure in `docs/runbooks/qbittorrent-wedge-recovery.md`.

## Remaining risk and prevention

### Kernel risk

The installed kernel reproduced the signature even though Ubuntu's advisory marks an earlier package fixed. Do not assume the package version alone eliminates the risk. Retain the trace, monitor Ubuntu kernel updates, and test a newer confirmed build before declaring the kernel issue closed.

### Shared CIFS incomplete-storage risk

All five clients currently perform incomplete torrent I/O directly on the CIFS share. A future design may place each instance's incomplete directory on local storage and move completed data to the share. That is a fleet architecture change with capacity, atomic-move, import, and recovery implications; it must not be applied only to Sonarr or without a maintenance plan.

### Mount health risk

Before restarting torrent workloads, verify the leaf mount itself—not merely its parent directory—is present and writable. A missing or read-only mount can cause downloads to land on the host filesystem or fail in confusing ways.

### Monitoring signals

Alert on:

- `netfs_read_gaps`;
- `cifs_strict_readv`;
- kernel oops, BUG, or NULL-pointer messages;
- `folio_wait_bit_common`;
- qBittorrent processes in `D` or `Z` state;
- Docker “failed to exit” or “did not receive an exit event” messages;
- missing container namespaces;
- `RTNETLINK answers: File exists` from Proton units;
- systemd `203/EXEC`;
- port-state, artifact, API, and Docker mapping disagreements;
- CIFS leaf mount becoming absent or read-only;
- fleet parity verifier failures.

## Evidence classification

To keep future incident reports precise:

- Confirmed: local command output, logs, process state, file descriptors, mount data, and source code observed during the incident.
- Strongly supported: the shared route delete/add race caused Sonarr's `EEXIST` failure.
- Signature match: CVE-2026-64064 or a closely related netfs defect.
- Context only: high NAS utilization; it was not demonstrated as the kernel-oops cause.
- Not established: corruption of the named torrent payload.

## Archive comparison

`/archive` was absent during the investigation. No claim in this report relies on an archived implementation or on speculation about how such an implementation behaved.
