# Incident: qBittorrent-Sonarr CIFS/netfs kernel wedge

## Document status

- Incident date: 2026-08-14
- Host timezone: America/Chicago (CDT)
- Affected service: `qbittorrent-sonarr`
- Related services: `proton-wg@sonarr`, `proton-port-forward@sonarr`, `proton-docker-watch@sonarr`, `proton-healthcheck@sonarr`
- Severity: service outage with host reboot required for complete recovery
- Investigation status: root cause established to the host-kernel/CIFS boundary; the repeated trace is a strong CVE-2026-64064 signature match, not proven identity
- Recovery status: the third reboot completed on 2026-08-17 and cleared the unreapable Sonarr tasks
- Containment status: `/mnt/data` is now mounted with `cache=none`; no recurrence has yet been observed on this fresh mount, but this is a mitigation rather than a demonstrated kernel fix
- Follow-up status: the latest canonical source was installed and the all-five structural rollout completed before the recurrence; its zombie guard correctly refused every attempted self-heal recreation

## Executive summary

`qbittorrent-sonarr` became impossible for Docker to stop or recreate because a qBittorrent worker faulted inside the Linux `netfs`/CIFS buffered-read path. The kernel oops killed one execution context while another qBittorrent thread remained blocked in uninterruptible `D` state, waiting in `folio_wait_bit_common`. The qBittorrent process leader later became a zombie.

Docker delivered `SIGTERM`, waited the configured 90-second grace period, escalated to `SIGKILL`, and then attempted a direct kill. None of those actions could complete the container lifecycle because signals cannot release a thread sleeping uninterruptibly inside kernel I/O. Docker consequently retained the old container identity while portions of its namespaces had already disappeared. Health checks then failed before `curl` could run.

This was not a Web UI failure, ordinary qBittorrent deadlock, stale lockfile, memory exhaustion, or Docker restart-policy problem. The immediate recovery boundary was the host kernel. The required host reboot completed on 2026-08-15, but the same failure recurred later that day on a different incomplete file. A second reboot on 2026-08-16 cleared that wedge but exposed a separate NAS mount-order failure. The kernel oops then recurred for a third time at 19:05 CDT on 2026-08-17 while `/mnt/data` still used `cache=strict`.

The coordinated 20:16 CDT reboot on 2026-08-17 cleared the third unreapable task and created the first live `/mnt/data` mount with `cache=none`. All five qBittorrent instances passed post-boot verification with uploading and seeding still enabled. No recurrence has yet been observed on that fresh mount. This supports `cache=none` as the active fleet-wide containment measure; it does not demonstrate that the kernel defect is repaired.

Three independent automation defects would have prevented clean service recovery even after the kernel task disappeared:

1. Sonarr's Proton WireGuard unit had been failed since 2026-08-09 after concurrent instances raced while replacing shared policy-routing rules and one received `RTNETLINK answers: File exists`.
2. The qBittorrent allocator systemd unit executed a non-executable script from the source checkout and failed with systemd `203/EXEC`.
3. The managed port artifact stored the same port under both `QBT_PUBLISHED_PORT` and the unused `QBT_FORWARDED_PORT`, creating two supposed sources of truth.

The corrective implementation serializes all shared route mutations, installs every systemd executable from `/usr/local/bin/proton`, reduces the port artifact to one assignment, samples LWP IDs to distinguish transient CIFS waits from persistent kernel `D` state, makes forced fleet sync wait for its per-instance lock, centralizes Compose policy for all five qBittorrent services, and adds fleet-wide verification and rolling reconciliation tools.

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

All three recorded oops events occurred before the fresh `cache=none` mount was activated. The current post-recovery mount option is therefore not part of the failure environment.

The qBittorrent config volume under `/opt/qbittorrent-sonarr/config` is local ext4. The blocked file was on the CIFS-backed data volume, not the local config volume.

## Exact I/O target

The blocked qBittorrent thread held two file descriptors to this incomplete torrent file:

```text
/data/downloads/torrents/incomplete/Breaking.Bad.S01-S05.REPACK.COMPLETE.1080p.BluRay.REMUX.AVC.DTS-HD.MA.5.1-FraMeSToR/Breaking.Bad.S02E12.Phoenix.REPACK2.1080p.DTS-HD.MA.5.1.AVC.REMUX-FraMeSToR.mkv
```

Inside the container, `/data` maps to host `/mnt/data`. The path identifies the operation that was in progress; it does not prove that the media file itself is corrupt. Do not delete it solely because it appears in the blocked descriptors. After recovery, use qBittorrent's force-recheck and inspect storage/kernel logs before deciding whether any payload is damaged.

## Timeline

### Recurrence after recovery

- 2026-08-15 06:01:35 UTC: the structurally reconciled Sonarr container started.
- 2026-08-15 18:24:54 CDT: kernel `7.0.0-29-generic` logged another NULL-pointer dereference at address `0x8` in `netfs_read_gaps+0x3f/0x4b0`.
- The repeated stack again included `netfs_read_folio`, `netfs_buffered_read_iter`, `cifs_strict_readv`, and `do_preadv`.
- The faulting context exited, the qBittorrent leader became a zombie, and two surviving LWPs remained in `D` state despite pending `SIGKILL`.
- LWP `294227` remained in `folio_wait_bit_common`; LWP `294229` remained in `process_measurement`.
- Both surviving LWPs held descriptors `228` and `245` to a different incomplete media file, `Better.Call.Saul.S03E02.Witness.1080p.DTS-HD.MA.5.1.AVC.REMUX-FraMeSToR.mkv`.
- The CIFS leaf mount remained responsive, reported no failed reads or writes in the sampled counters, and remained approximately 97% utilized.
- Sonarr automation retried approximately every 45 seconds, but the deployed zombie guard refused Compose recreation each time.
- 2026-08-16 08:50:44 CDT: `proton-port-forward@sonarr`, `proton-docker-watch@sonarr`, and `proton-healthcheck@sonarr` were stopped. `proton-wg@sonarr` remained active.

### Second reboot and mount-order recovery

- 2026-08-16 09:04:04 CDT: the host booted again into `7.0.0-29-generic`; the stale Sonarr zombie and uninterruptible tasks were gone.
- NetworkManager reported startup complete at 09:04:16 before Ethernet carrier appeared at 09:04:20 and before DHCP completed at 09:04:25.
- Docker started at 09:04:16 and accessed `/mnt/data` and `/mnt/plex` at 09:04:17. Both CIFS mounts failed with `-101` (`Network is unreachable`) and exhausted their systemd start limits.
- Containers with either NAS path as a bind source failed safely before startup. No qBittorrent container wrote through the uncovered local `/mnt/data` directory.
- After the NAS route and TCP port 445 became reachable, both automounts were reset and restored. Known NAS leaf directories resolved correctly before containers were started.
- All five existing qBittorrent containers started without recreation and passed the installed fleet verifier.
- A `nas-network-online.service` readiness gate and mount-unit drop-ins were deployed. Both CIFS mounts now require a successful route and SMB socket check before mount attempts begin.
- Startup torrent verification generated more than 34 GB of CIFS reads. Several qBittorrent LWPs entered transient or recurring `D` states while the load drained, but no new kernel oops, SMB operation failure, or reconnect was observed during validation.

### Third recurrence and performance collapse

- 2026-08-17 19:05:07 CDT: kernel `7.0.0-29-generic` logged a third NULL-pointer dereference at address `0x8` in `netfs_read_gaps+0x3f/0x4b0`.
- The call trace again entered `netfs_read_folio`, `filemap_read_folio`, `netfs_buffered_read_iter`, `cifs_strict_readv`, and `do_preadv`.
- The faulting qBittorrent context, PID `2216279`, exited with interrupts disabled.
- Two surviving Sonarr workers, LWPs `2216277` and `2216278`, remained in `D` state for more than 11 hours in `process_measurement` and `folio_wait_bit_common`.
- Their open descriptors included both incomplete Better Call Saul downloads and completed cross-seed payloads on `/data`, confirming that the faulted CIFS path affects downloading and seeding I/O.
- Sonarr remained connected through Proton with no tunnel receive errors. Six downloading torrents reported 306 aggregate seeds and high availability, ruling out swarm scarcity as the primary bottleneck.
- Live download throughput was approximately 72 KiB/s against a 40 MiB/s configured limit. Libtorrent reported 117 queued I/O jobs, 58% write-cache overload, approximately 1.48 GiB of buffers, and 462 peer connections.
- The normalized `request_queue_size=2000` and `file_pool_size=5000` settings persisted. They did not release workers already trapped by the kernel fault.
- Torrent queueing remained disabled. No active-upload or seeding limit was introduced.
- CIFS remained reachable with zero failed reads or writes in the sampled counters and no session reconnects. A responsive share does not make the faulted task recoverable.

### Fleet-wide mount mitigation activated

- Local ext4 had approximately 1.37 TiB available, while the five qBittorrent instances reported approximately 3.34 TiB remaining across incomplete torrents and approximately 4.20 TiB of incomplete logical payload. Local incomplete storage is therefore not capacity-safe on the current host.
- 2026-08-17 19:05:07 CDT: the third kernel oops occurred while the existing `/mnt/data` mount still used `cache=strict`.
- 2026-08-17 20:01 CDT: the shared `/mnt/data` fstab entry was changed from the implicit `cache=strict` behavior to explicit `cache=none`. This is one mount-level policy for all five qBittorrent instances, not a Sonarr-only override.
- `findmnt --verify --verbose` reported zero parse errors and zero errors, and the regenerated `mnt-data.mount` contains `cache=none`.
- No live remount, qBittorrent restart, container recreation, or queueing change was attempted while persistent `D`-state workers remained.
- 2026-08-17 20:16 CDT: the coordinated reboot cleared the stale tasks and produced the first live `/mnt/data` mount with `cache=none`.
- This ordering proves that the 19:05 oops preceded the mitigation. It must not be described as a failure under `cache=none`.
- Post-boot static, protected-config, and runtime verification passed for all five qBittorrent instances. Uploading and seeding remained enabled; no active-upload or queueing limit was introduced as part of recovery.

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
8. The sync script detects zombies immediately and rejects only persistent same-LWP `D`-state conditions after multiple samples, allowing transient CIFS waits to clear.
9. WireGuard up/down and Docker watcher route changes use one global route lock.
10. Both nftables and iptables kill-switch backends use one host-wide kill-switch lock.
11. The allocator script and unit are installed through the canonical deployment path.
12. The generated Docker network name is corrected to `starr_network`.
13. Full live interface names `pvprowlarr` and `pvwhisparr` replace shortened stale examples.
14. Static, protected-config, and runtime fleet verifiers enforce parity.
15. A rolling reconciler can force all five containers through the same shared structural change while preserving each instance's own Proton lease.
16. Forced fleet synchronization waits for each per-instance sync lock and fails on timeout instead of silently skipping an instance with exit status zero.
17. The installer reconciles required manifest-owned table, priority, and instance-name keys into preserved protected configs without overwriting secrets.
18. `mnt-data.mount` and `mnt-plex.mount` require and follow `nas-network-online.service`, which waits for both a route to the NAS and a successful TCP connection to port 445.
19. Docker wants and follows all five `proton-wg@<instance>.service` units. This orders tunnel activation before Docker without treating `Wants=` as proof that every tunnel is healthy; the kill switch remains the leak-prevention boundary.
20. The shared `/mnt/data` mount uses `cache=none` for every qBittorrent instance and every other consumer of that mount.
21. Recovery introduced no torrent queueing, active-upload limit, seeding limit, or Sonarr-only storage exception.

## Recovery update and remaining closure work

The host reboot began at 2026-08-15 00:11 CDT, and the host reboot completed on 2026-08-15. It removed the stale zombie and persistent `folio_wait_bit_common` task. Sonarr subsequently started healthy with its renewed Proton lease, and the all-five runtime verifier passed. That recovery was temporary: the kernel wedge recurred later the same day and again on 2026-08-17.

Activation also exposed two control-plane defects: one-snapshot `D` checks falsely rejected transient CIFS I/O, and newline-separated shell commands allowed a later successful verifier to hide an earlier failed structural rollout. The canonical source now samples the same LWP across multiple checks, makes forced lock contention fail, and documents `&&`-chained activation. The guard behaved correctly during both recurrences and prevented Docker stop/recreate loops.

At 20:16 CDT on 2026-08-17, the third coordinated reboot cleared the unreapable tasks and activated `cache=none`. The NAS readiness and Docker/tunnel ordering drop-ins were deployed, both CIFS leaves mounted through their route-and-SMB gate, and all five qBittorrent instances passed static, protected-config, and runtime verification. Uploading and seeding remained active.

Remaining closure work is:

1. report all three recurrences against Ubuntu kernel `7.0.0-29.29`, including the traces and the conflict with the CVE tracker's fixed status;
2. continue sustained-load validation of the active `cache=none` mitigation across all five clients and other `/mnt/data` consumers;
3. force-recheck affected torrents before treating their payloads as trustworthy if that validation has not already been completed;
4. qualify a future supported Ubuntu kernel by exact patch provenance and controlled workload testing rather than by package number alone;
5. monitor for renewed `netfs`, CIFS, folio, persistent `D`-state, or Docker kill-timeout symptoms.

Use the detailed procedure in `docs/runbooks/qbittorrent-wedge-recovery.md`.

## Remaining risk and prevention

### Kernel risk

The installed Ubuntu `7.0.0-29.29` kernel reproduced the signature three times even though Ubuntu's advisory marks an earlier package fixed. The host's local APT metadata still offered `-29` during the incident follow-up, while Launchpad now publishes `7.0.0-30.30` in updates. The `-30` changelog adds an unrelated Open vSwitch CVE fix and no relevant netfs correction. `7.0.0-31.31` remains proposed-only; it incorporates upstream stable changes through Linux 7.1.4, but neither its channel nor its changelog demonstrates a fix for this incident. Do not install or recommend `-31` as a production repair on that basis.

Upstream commit `156ac2ec` repairs dirty folio state removed by truncation before `netfs_read_gaps()`. Linux 7.1.8 contains later writeback error and `ENOMEM` iteration-state repairs in `ac5f95ac` and `b6a713fd`. Linux 7.2 contains the newer asynchronous writeback-exclusion design in `41376400`, replacing `netfs_inode::wb_lock` with bit-based exclusion held through result collection. These are relevant repairs, but none has been demonstrated to prevent this exact production oops. Keep `cache=none` active, use only a normally supported Ubuntu publication after qualification, and require controlled all-five workload testing before declaring the kernel issue closed.

Version and provenance references:

- Ubuntu `7.0.0-30.30`: <https://launchpad.net/ubuntu/+source/linux/7.0.0-30.30>
- Ubuntu `7.0.0-31.31`: <https://launchpad.net/ubuntu/+source/linux/7.0.0-31.31>
- current and stable upstream releases at review time: <https://www.kernel.org/>

### Shared CIFS incomplete-storage risk

All five clients currently perform incomplete torrent I/O directly on the CIFS share. Local ext4 capacity is insufficient for the fleet's current incomplete workload, so a future local-incomplete design requires additional storage as well as a fleet architecture plan for capacity, cross-filesystem completion moves, imports, and recovery. It must never be applied to only one qBittorrent instance.

The active fstab entry and live `/mnt/data` mount use `cache=none`. The third oops occurred at 19:05 CDT, the fstab edit was made at 20:01, and the fresh mount was activated by reboot at 20:16 on 2026-08-17. `mount.cifs(8)` documents that `cache=none` bypasses the client page cache for normal reads and writes; it therefore avoids the observed `cifs_strict_readv` path for ordinary qBittorrent `preadv` calls. It remains a mitigation, not a demonstrated kernel fix, and mmap still uses page cache. Because the option affects every consumer of `/mnt/data`, continue throughput and correctness monitoring under sustained load.

### Boot-order risk

The 2026-08-16 boot proved that NetworkManager's startup-complete signal could precede carrier, DHCP, and NAS reachability. The deployed readiness graph has two explicit protections:

1. `mnt-data.mount` and `mnt-plex.mount` have `Requires=` and `After=` on `nas-network-online.service`; that service succeeds only after both route lookup and TCP port 445 reachability succeed.
2. `docker.service` has `Wants=` and `After=` on all five Proton WireGuard units, so their activation is attempted before Docker starts. This is ordering, not a tunnel-health assertion; runtime verification and the host kill switch remain mandatory.

Do not remove either drop-in as unrelated boot cleanup. After a reboot, verify the CIFS leaves, all five tunnel units, Docker, and the fleet runtime contract before accepting torrent workload recovery.

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
