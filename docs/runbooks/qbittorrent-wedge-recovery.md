# Runbook: qBittorrent container and kernel-I/O wedge recovery

## Purpose

Use this runbook when a managed qBittorrent container is reported as running but cannot pass its health check, stop, be removed, or be recreated. It is written for the 2026-08-14 `qbittorrent-sonarr` incident, but the decision process applies to all five managed instances:

- `qbittorrent-lidarr`
- `qbittorrent-prowlarr`
- `qbittorrent-radarr`
- `qbittorrent-sonarr`
- `qbittorrent-whisparr`

This procedure deliberately separates an ordinary application failure from a Docker lifecycle failure and from an uninterruptible kernel-I/O failure. The recovery boundary is different in each case. Do not escalate through increasingly forceful kill commands without first identifying which branch applies.

## Safety rules

1. Do not run bare `docker compose up` in a qBittorrent project. The wrappers intentionally refuse to render without the active Proton lease injected as `QBT_PUBLISHED_PORT`.
2. Do not copy a port from one instance to another. Every Proton tunnel has an independent NAT-PMP lease.
3. Do not repeatedly force-recreate a container that still owns its Docker name. That creates orphan/name-conflict loops without repairing a stuck task.
4. Do not kill `containerd-shim`, write `cgroup.kill`, detach CIFS, or force-unmount storage when a process remains in uninterruptible `D` state across samples. Those operations cannot repair damaged in-kernel state and can make evidence and runtime bookkeeping worse.
5. A reboot is a host-wide disruptive action. Obtain approval and coordinate the outage before executing it.
6. Preserve evidence before reboot. `/proc`, kernel ring-buffer, and runtime namespace evidence disappears when the host restarts.
7. Apply structural corrections to the complete five-instance fleet. Recovery of the affected workload may be staged first, but the fleet must either finish the same rollout or be rolled back to one version.
8. Preserve uploading and seeding availability. Do not introduce torrent queueing, active-upload limits, seeding limits, or a one-instance storage exception as a wedge workaround. A coordinated reboot interrupts the host, but the accepted post-recovery state restores all five clients without suppressing completed uploads.

## Fast decision table

| Evidence | Classification | Permitted next action |
| --- | --- | --- |
| Web UI fails; container tasks are normal `S`/`R`; Docker stop works | application failure | one guarded per-instance sync/recreate |
| Container says running, has missing namespaces or no published ports, tasks are killable, no persistent `D` state/kernel oops | userspace runtime/container lifecycle wedge | stop automation, capture evidence, perform targeted runtime cleanup only after confirming all tasks are killable |
| The same task remains `D` across samples, especially in `folio_wait_bit_common`, with CIFS/netfs errors or a kernel oops | host-kernel/storage wedge | stop mutation attempts, capture evidence, schedule host reboot |
| qBittorrent process leader is `Z` while another thread remains `D` across samples | host-kernel/storage wedge | reboot; killing the zombie parent or shim is not a repair |
| `docker kill` reports no exit event after `SIGKILL` | inspect for `D` state immediately | follow the matching branch; do not keep retrying |

## Instance reference

| Instance | Container/service | Web UI | Bind IP | VPN interface |
| --- | --- | ---: | --- | --- |
| Lidarr | `qbittorrent-lidarr` | 8081 | 10.2.0.2 | `pvlidarr` |
| Prowlarr | `qbittorrent-prowlarr` | 8082 | 10.6.0.2 | `pvprowlarr` |
| Radarr | `qbittorrent-radarr` | 8083 | 10.3.0.2 | `pvradarr` |
| Sonarr | `qbittorrent-sonarr` | 8084 | 10.4.0.2 | `pvsonarr` |
| Whisparr | `qbittorrent-whisparr` | 8085 | 10.5.0.2 | `pvwhisparr` |

The authoritative machine-readable catalog is `/opt/qbittorrent-common/qbittorrent-instances.tsv`.

## Phase 1: Freeze automation and capture evidence

Set the affected instance in a shell variable. The examples use Sonarr:

```bash
instance=sonarr
container="qbittorrent-${instance}"
```

Stop only the automation that might repeatedly operate on the affected container. Do not bring down the WireGuard tunnel yet; the blocked task may still hold storage or network state, and preserving current state helps investigation.

```bash
sudo systemctl stop \
  "proton-port-forward@${instance}.service" \
  "proton-docker-watch@${instance}.service" \
  "proton-healthcheck@${instance}.service"
```

Record Docker identity and state:

```bash
date --iso-8601=seconds
uname -a
docker ps -a --no-trunc --filter "name=^/${container}$" \
  --format 'ID={{.ID}} Name={{.Names}} Status={{.Status}} Ports={{.Ports}}'
docker inspect "$container" --format \
  'PID={{.State.Pid}} Status={{.State.Status}} Running={{.State.Running}} OOM={{.State.OOMKilled}} Exit={{.State.ExitCode}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} Ports={{json .NetworkSettings.Ports}}'
docker top "$container" -eLo pid,lwp,ppid,user,stat,wchan:48,etime,cmd
```

Record the per-instance service timeline:

```bash
sudo journalctl --no-pager -o short-iso -n 500 \
  -u "proton-wg@${instance}.service" \
  -u "proton-port-forward@${instance}.service" \
  -u "proton-docker-watch@${instance}.service" \
  -u "proton-healthcheck@${instance}.service"
```

Record Docker/runtime and kernel symptoms:

```bash
sudo journalctl --no-pager -k --since '24 hours ago' | \
  grep -Ei 'BUG:|Oops:|netfs|cifs|folio|hung task|blocked for more than|I/O error'
sudo journalctl --no-pager -u docker.service -u containerd.service \
  --since '2 hours ago' | tail -500
```

Record storage topology. Verify the leaf mount, not only `/mnt/data`'s parent:

```bash
findmnt -T /mnt/data -o TARGET,SOURCE,FSTYPE,OPTIONS
df -hT /mnt/data
mountpoint /mnt/data
```

Do not include qBittorrent credentials, WireGuard private keys, cookies, or full protected environment files in an incident ticket.

## Phase 2: Classify every container task

Get the container init PID and inspect all threads visible on the host:

```bash
pid=$(docker inspect "$container" --format '{{.State.Pid}}')
ps -T -p "$pid" -o pid,tid,ppid,user,stat,wchan:48,etime,cmd

for status in "/proc/${pid}"/task/*/status; do
  awk -v file="$status" '
    $1 == "Name:"  { name=$2 }
    $1 == "Pid:"   { tid=$2 }
    $1 == "State:" { print file, "tid=" tid, "name=" name, "state=" $2, $3 }
  ' "$status"
done
```

If Docker's init PID has already partially disappeared, use the PIDs/TIDs returned by the last successful `docker top` or journal evidence. For each suspect task:

```bash
suspect_pid=<pid-or-tid>
sed -n '1,100p' "/proc/${suspect_pid}/status"
cat "/proc/${suspect_pid}/wchan"
sudo cat "/proc/${suspect_pid}/stack"
```

Interpret the `STAT` column:

- `S`, `R`, or `I`: sleeping/runnable/idle; these do not by themselves prevent signal delivery.
- `Z`: zombie; the task exited but its parent/runtime has not reaped it.
- `D`: uninterruptible sleep, normally waiting in the kernel for I/O. `SIGKILL` remains pending until the task returns from that wait.

A one-snapshot `D` state can be ordinary transient CIFS I/O. Record the LWP/TID and sample it again before classifying a kernel wedge. The automation uses the same rule: it rejects recreation only when the same LWP remains `D` across multiple samples. A kernel oops or Docker kill timeout still requires an immediate mutation freeze while evidence is collected.

The decisive 2026-08-14 Sonarr pattern was:

```text
qbittorrent-nox leader: Z
surviving qBittorrent thread: Dsl
wait channel: folio_wait_bit_common
kernel trace: netfs_read_gaps -> netfs_read_folio -> cifs_strict_readv
```

That combination selects the host-kernel recovery branch.

## Branch A: ordinary application failure

Use this branch only when all of the following are true:

- no task remains in `D` state across samples;
- no relevant kernel oops/hung-I/O trace exists;
- the named container is not stuck in `removing` or partial namespace teardown;
- Docker can stop/remove the container normally;
- the instance was not intentionally stopped.

Check the complete fleet before changing anything:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --check
```

If only the active lease for one instance needs applying, invoke its allocator:

```bash
sudo systemctl start "proton-qbt-allocate@${instance}.service"
sudo systemctl status "proton-qbt-allocate@${instance}.service" --no-pager -l
```

This path obtains the instance's own current Proton port and recreates only its matching qBittorrent container when necessary. Do not use the fleet `--recreate` mode for a single lease change.

## Branch B: userspace Docker/runtime lifecycle wedge

Use this branch only after proving that no container task remains in `D` state across samples and there is no kernel/CIFS oops associated with the failure. Capture all Phase 1 evidence first.

1. Keep the affected instance's Proton watcher, port-forward, and healthcheck stopped.
2. Attempt one normal Docker stop/remove with a bounded timeout.
3. If all container tasks have exited but Docker retained stale metadata, investigate the matching containerd shim and runtime state.
4. Restarting Docker or containerd is host-wide to all containers and requires an explicit maintenance decision.
5. After runtime cleanup, start the Proton chain and use the allocator/synchronizer. Never hand-type a historical/reference port.

This document intentionally does not prescribe a generic `kill -9` of a shim. The exact shim must be correlated to the full container ID, all tasks must be proved killable or exited, and the blast radius of restarting the runtime must be assessed on the live host. If those facts cannot be established, choose a coordinated host reboot rather than destructive runtime surgery.

## Branch C: kernel/CIFS/netfs wedge

Use this branch when the same relevant task remains in `D` state across samples or a kernel oops has damaged the I/O path.

### Stop making container mutations

Do not repeat:

```text
docker stop
docker kill
docker rm -f
docker compose up --force-recreate
cgroup.kill
kill -9 <containerd-shim>
umount -f /mnt/data
```

The first attempts may be useful diagnostic evidence. Once persistent `D` state is confirmed, retries cannot force signal handling and may obscure the incident.

### Prepare the host reboot

1. Save the evidence from Phases 1 and 2 outside volatile `/run` and `/proc`.
2. Record `uname -a`, the installed/running kernel packages, CIFS mount options, affected path, container ID, PIDs/TIDs, call trace, and timestamps.
3. Stop new download/import activity from Sonarr/Radarr/Lidarr/Whisparr/Prowlarr where practical.
4. Confirm out-of-band or local console access if the host is remote.
5. Confirm that SSH and RDP policy-routing bypasses are still intact before the maintenance window.
6. Notify users of a host-wide outage.
7. Obtain explicit approval for the reboot.

### Reboot

The approved operator performs:

```bash
sudo systemctl reboot
```

Do not call the incident recovered merely because the old PID disappeared. Complete every post-reboot gate below.

## Phase 3: post-reboot storage gate

Before any qBittorrent client writes incomplete data, verify:

```bash
uname -a
findmnt -T /mnt/data -o TARGET,SOURCE,FSTYPE,OPTIONS
mountpoint /mnt/data
df -hT /mnt/data
```

For the current fleet baseline, the live CIFS leaf must report `cache=none`. The third oops occurred at 19:05 CDT on 2026-08-17 under `cache=strict`; fstab changed at 20:01, and the 20:16 reboot created the first live `cache=none` mount. Do not attribute that oops to the mitigation.

Perform a bounded write/read/delete test in an operator-approved scratch directory on the actual mounted share:

```bash
test_dir=/mnt/data/.proton-qbt-recovery-check
sudo install -d -m 0755 "$test_dir"
printf 'qbt-recovery %s\n' "$(date --iso-8601=seconds)" | sudo tee "$test_dir/probe" >/dev/null
sudo cat "$test_dir/probe"
sudo rm "$test_dir/probe"
sudo rmdir "$test_dir"
```

The two delete commands above target only the explicit scratch objects created by this procedure. Stop if the leaf mount is missing, unexpectedly local, read-only, stale, or returns an I/O error. Do not start torrents onto the host filesystem beneath an absent mount.

Inspect the new boot for immediate storage/kernel faults:

```bash
sudo journalctl -b -k --no-pager | \
  grep -Ei 'BUG:|Oops:|netfs|cifs|folio|hung task|blocked for more than|I/O error'
```

## Phase 4: deploy and validate the corrected automation

Before restarting the failed workload, verify that deployed executables and units no longer use the source checkout:

```bash
systemctl cat proton-qbt-allocate@.service
systemctl cat mnt-data.mount
systemctl cat mnt-plex.mount
systemctl cat docker.service
stat -c '%a %U:%G %n' \
  /usr/local/bin/proton/proton-qbt-allocate-and-sync.sh \
  /usr/local/bin/proton/proton-qbittorrent-sync-safe.sh
```

Required allocator properties:

```text
ExecStart=/usr/local/bin/proton/proton-qbt-allocate-and-sync.sh %i
mode 755
```

Required boot-order properties:

- both CIFS mount units require and follow `nas-network-online.service`;
- the NAS gate checks both a route and TCP port 445 before succeeding;
- Docker wants and follows all five `proton-wg@<instance>.service` units.

`Wants=` orders and attempts the five tunnel units but does not prove they all succeeded. Keep the kill switch and runtime verifier as independent gates.

Run protected preflight:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --preflight
```

It must prove:

- all five wrappers extend the common Compose policy;
- all five project `.env` files have exactly one `QBT_HOST_BIND_IP` assignment;
- every dynamic artifact has exactly one `QBT_PUBLISHED_PORT` assignment;
- no `QBT_FORWARDED_PORT` alias remains;
- full interface names and `starr_network` are consistent;
- manifest-owned `VPN_TABLE`, `QBT_VPN_RULE_PRIORITY`, and `QBT_INSTANCE_NAME` values are present in existing protected configs;
- per-instance identity, path, table, priority, URL, and service name match the manifest.

## Phase 5: restart Proton instances sequentially

Normal boot now orders Docker after all five Proton WireGuard activation attempts, while both NAS mount units wait for the route-and-SMB readiness service. First inspect the units that systemd already started. Do not restart a healthy chain merely to reproduce the sequence.

If an instance chain is inactive after the storage gate and evidence capture, the route-race fix allows concurrent activation, but sequential recovery gives a clearer failure boundary. Start one instance chain at a time:

```bash
for instance in lidarr prowlarr radarr sonarr whisparr; do
  sudo systemctl reset-failed \
    "proton-wg@${instance}.service" \
    "proton-port-forward@${instance}.service" \
    "proton-docker-watch@${instance}.service" \
    "proton-healthcheck@${instance}.service" \
    "proton-qbt-allocate@${instance}.service"

  sudo systemctl start "proton-wg@${instance}.service"
  sudo systemctl start "proton-port-forward@${instance}.service"
  sudo systemctl start "proton-docker-watch@${instance}.service"
  sudo systemctl start "proton-healthcheck@${instance}.service"
  sudo systemctl start "proton-qbt-allocate@${instance}.service"

  systemctl is-active "proton-wg@${instance}.service"
  systemctl is-active "proton-port-forward@${instance}.service"
done
```

If an instance fails, stop the sequence. Capture its journal and repair the common mechanism before continuing; do not introduce a one-instance script fork.

## Phase 6: fleet acceptance

Run the complete runtime verifier:

```bash
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

For every instance it must prove:

```text
CURRENT_PORT
  == QBT_PUBLISHED_PORT
  == container TORRENTING_PORT
  == Docker TCP host/target port
  == Docker UDP host/target port
  == qBittorrent Session\Port
```

It must also prove that the torrent port binds only to that instance's tunnel IP, the container is healthy, and the five static contracts are aligned.

Inspect policy routing and tunnels:

```bash
ip -4 rule show
ip -4 route show table all
wg show
```

Each qBittorrent container source `/32` must select its own VPN table. Shared priority-108/109 main-table exceptions must exist once, without duplicate rule races.

## Phase 7: workload repair

For the 2026-08-14 Sonarr incident:

1. Confirm the incomplete Breaking Bad payload still exists at the expected CIFS path.
2. Do not assume it is corrupt merely because it was open during the kernel fault.
3. In `qbittorrent-sonarr`, force-recheck the affected torrent.
4. Resume it only after the recheck and storage gate succeed.
5. Confirm Sonarr sees the qBittorrent client as available.
6. Watch the first read/write activity for renewed CIFS/netfs errors.

Apply analogous checks to any instance affected in a future event.

## Monitoring after recovery

For at least one full workload cycle, monitor:

```bash
sudo journalctl -f -k | grep -Ei 'BUG:|Oops:|netfs|cifs|folio|hung task|I/O error'
```

In another terminal:

```bash
sudo journalctl -f \
  -u 'proton-wg@*.service' \
  -u 'proton-port-forward@*.service' \
  -u 'proton-docker-watch@*.service' \
  -u 'proton-healthcheck@*.service'
```

Alert-worthy conditions include:

- the same qBittorrent task remaining in `D` state across samples;
- `folio_wait_bit_common`, `netfs_read_gaps`, or `cifs_strict_readv` in a blocked-task/oops trace;
- Docker stop timeout or “did not receive an exit event”;
- health-check failure before the command can enter a container namespace;
- `RTNETLINK answers: File exists` during Proton startup;
- systemd `203/EXEC`;
- persistent artifact/live lease/Docker port divergence;
- a dynamic torrent port bound to `0.0.0.0`.

## Longer-term CIFS risk decision

All five clients currently use `/data/downloads/torrents/incomplete` on the shared CIFS mount. Moving incomplete data to local storage could reduce the amount of active random I/O through CIFS, but it is an architecture change, not an incident hotfix. It requires:

- enough local capacity for all five workloads;
- a fleet-wide path policy and explicit per-instance directories;
- consideration of cross-filesystem moves after completion;
- permissions and cleanup rules;
- import/hardlink behavior review;
- backup and rollback steps;
- validation on every qBittorrent instance.

Do not apply local incomplete storage only to Sonarr. If adopted, implement it through the shared fleet policy with documented, intentional per-instance path overrides.

On 2026-08-17, the fleet reported approximately 3.34 TiB remaining across incomplete torrents and approximately 4.20 TiB of incomplete logical payload, but local ext4 had only approximately 1.37 TiB available. Do not deploy local incomplete directories on this host without adding capacity for the whole fleet.

The capacity-independent mitigation is active: the shared `/mnt/data` fstab entry and live mount use `cache=none`. This applies to all five instances through their common mount and also affects every other `/mnt/data` consumer. Never attempt a live remount while a qBittorrent task remains persistently uninterruptible. If the option must change, validate fstab and activate the change only through a coordinated reboot. After boot:

1. confirm the live `/mnt/data` CIFS leaf reports `cache=none`;
2. confirm no stale qBittorrent `D`- or `Z`-state task remains;
3. run static, protected-config, and runtime verification for all five instances;
4. compare fleet throughput, CIFS errors, and kernel logs under sustained load;
5. roll back to the prior fstab option and reboot if broad `/mnt/data` behavior regresses.

The timing is authoritative: oops at 19:05 CDT, fstab edit at 20:01, fresh `cache=none` mount at 20:16 on 2026-08-17. The current absence of recurrence is evidence for containment, not proof of a kernel repair.

## Kernel upgrade qualification

Do not select a kernel from its version number alone:

- the host ran Ubuntu `7.0.0-29.29`, despite Ubuntu's tracker marking an earlier package fixed;
- Ubuntu `7.0.0-30.30` is published in updates but has no relevant netfs change;
- Ubuntu `7.0.0-31.31` is proposed-only, includes upstream stable changes through Linux 7.1.4, and is not a demonstrated fix;
- Linux 7.1.8 adds later netfs writeback error and `ENOMEM` iteration-state repairs;
- Linux 7.2 adds asynchronous writeback exclusion held through result collection.

The latter changes are relevant but do not prove prevention of this exact `netfs_read_gaps` oops. Keep `cache=none` in place while qualifying a normally published Ubuntu kernel. Before production adoption, verify exact patch provenance, boot the candidate only during a maintenance window, run all-five storage and runtime gates, exercise representative downloading and seeding I/O, and retain a known bootable rollback kernel.

## Incident closure criteria

The incident is closed only when all of the following are true:

- the host was rebooted and no stale blocked task remains;
- `/mnt/data` is the expected writable CIFS leaf mount with active `cache=none`;
- both NAS mount units contain the readiness dependency and Docker is ordered after all five WireGuard units;
- corrected scripts/units are deployed from the canonical install path;
- the route-lock and allocator deployment defects are absent;
- all five one-key port artifacts pass schema validation;
- all five Proton chains are active as designed;
- full runtime fleet verification passes;
- the affected torrent was rechecked;
- no recurrence appeared during the observation window;
- uploading and seeding remain enabled without a new active-upload, seeding, or queueing limit;
- kernel/CIFS evidence and the suspected upstream signature were retained for follow-up.

These criteria close host recovery, not the upstream kernel question. The kernel issue remains open until a supported replacement has exact relevant provenance and passes controlled production qualification without recurrence.

## Related documents

- `docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md`
- `docs/architecture/qbittorrent-fleet-contract.md`
- `docs/runbooks/qbittorrent-port-sync.md`
- `docs/runbooks/qbittorrent-fleet-changes.md`
