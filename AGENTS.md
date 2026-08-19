# Proton Project Agent Guide

## Authority And Repository Location

- The canonical source repository is `/usr/local/bin/proton_project`.
- Treat `/opt/proton_project_work` as a non-authoritative working copy that may be stale. Do not patch, validate, or quote it as current unless the user explicitly asks to synchronize or inspect it.
- Installed production entrypoints live under `/usr/local/bin/proton`. Never edit installed copies directly; change canonical source, validate it, then run `install-proton-systemd.sh` with administrator approval.
- The worktree may already contain user changes. Preserve them and keep edits scoped.

## Safety Boundaries

- Never print or commit qBittorrent passwords, WireGuard private keys, cookie jars, or complete protected environment files.
- Do not reboot, restart Docker/containerd, force-unmount CIFS, kill shims, write `cgroup.kill`, or perform fleet/container recreation without explicit outage or runtime authorization.
- Administrator passwords must be entered by the user directly in the terminal. Never request or relay them through chat tools.
- Chain dependent activation commands with `&&`. A newline-separated verifier can mask an earlier failed installer or rollout because the shell reports only the final command's status.
- If `/archive` is absent or empty, say so explicitly and proceed without archive-based root-cause claims.
- Keep uploading and seeding enabled. Do not introduce torrent queueing, active-upload limits, seeding limits, or a one-instance storage exception as an incident workaround. Shared changes roll sequentially so the other four clients remain available while one member is reconciled.

## qBittorrent Fleet Contract

- Managed instances: `lidarr`, `prowlarr`, `radarr`, `sonarr`, and `whisparr`.
- `qbittorrent-compose.common.yml` owns shared image, environment, volume, health, restart, shutdown, and network policy.
- `qbittorrent-instances.tsv` owns instance identity: Web UI port, bind IP, interface, subnet, route table, and qBittorrent rule priority.
- Each `/opt/qbittorrent-<instance>/docker-compose.yml` remains a thin wrapper around the shared policy.
- Each project `.env` contains exactly one assignment: `QBT_HOST_BIND_IP`.
- Each protected dynamic artifact contains exactly one assignment: `QBT_PUBLISHED_PORT`. `QBT_FORWARDED_PORT` is prohibited.
- Compose must require an explicitly injected Proton port and VPN bind IP. Never add a stale-port or `0.0.0.0` fallback.
- A lease change recreates only its owning container. A shared structural change rolls all five sequentially through the fleet reconciler.
- Never copy a complete `qBittorrent.conf` or one instance's lease to another instance.

## Installer And Runtime Invariants

- `install-proton-systemd.sh` installs executables under `/usr/local/bin/proton`, units under `/etc/systemd/system`, and shared fleet files under `/opt/qbittorrent-common`.
- The installer preserves secrets while reconciling required non-secret keys in existing instance configs: `VPN_TABLE`, `QBT_VPN_RULE_PRIORITY`, and `QBT_INSTANCE_NAME`.
- Existing port artifacts are atomically normalized to one valid `QBT_PUBLISHED_PORT` while preserving the port.
- Systemd `ExecStart` paths must never target the source checkout.
- Shared policy-route mutation uses `/run/proton/policy-routing.lock`; host-wide firewall mutation uses `/run/proton/killswitch.lock`.
- Ordinary per-instance sync is non-blocking and may skip when its lock is busy. Forced fleet sync waits for the lock and fails on timeout; it must never silently report success without recreating the instance.

## Host Storage And Boot Invariants

- The live SMB 3.1.1 `/mnt/data` mount uses `cache=none`. This is the active fleet-wide mitigation for all five qBittorrent clients and every other `/mnt/data` consumer, not a staged option or a demonstrated kernel fix.
- The third oops occurred at 19:05 CDT on 2026-08-17 under `cache=strict`; fstab changed at 20:01, and the 20:16 reboot created the first live `cache=none` mount. Never attribute that oops to `cache=none`.
- `mnt-data.mount` and `mnt-plex.mount` require and follow `nas-network-online.service`, which checks both NAS route availability and TCP port 445 before succeeding.
- Docker wants and follows all five `proton-wg@<instance>.service` units. This is startup ordering, not proof of tunnel health; the kill switch and runtime verifier remain required.
- `install-proton-systemd.sh` owns both the NAS mount drop-ins and the Docker tunnel-ordering drop-in. Update and validate the installer source rather than editing installed drop-ins as one-off fixes.
- Local incomplete storage is not capacity-safe for the current fleet. Any future storage-layout change is shared fleet structure and requires capacity, import/move, permissions, cleanup, rollback, and all-five validation.

## Wedge Detection

- A zombie is an immediate recreation refusal.
- A single `D`-state snapshot can be normal transient CIFS I/O. Automation samples LWP IDs and treats only the same task remaining in `D` state across samples as a persistent wedge.
- Persistent `D` state, especially with `folio_wait_bit_common` plus CIFS/netfs errors or a kernel oops, is a host-kernel recovery boundary. Preserve evidence and require a coordinated reboot; repeated signals or Docker cleanup cannot repair it.
- Human incident triage may stop mutation on the first observed `D` state while sampling and kernel evidence are collected. Do not weaken the persistent-wedge guard to bypass a real blocked task.
- Do not call a kernel version the fix without exact patch provenance and workload validation. Ubuntu `7.0.0-30.30` has no relevant netfs change, `7.0.0-31.31` is proposed-only, and the related Linux 7.1.8 and 7.2 repairs have not been demonstrated to prevent this exact oops.

## Change Workflow

1. Start from canonical source and inspect the owning script, nearby tests, and relevant runbook.
2. State whether the change is per-instance runtime behavior, shared fleet structure, or an intentional role override.
3. Make the smallest shared-source change. Do not create instance forks for common behavior.
4. Add behavioral tests for control-flow and safety changes; grep-only assertions are supplementary.
5. Run focused tests immediately after the first edit, then the full suite and static checks.
6. Update architecture, runbooks, incident status, and operator commands when behavior or recovery boundaries change.
7. Deploy only after explicit authorization. Verify source/installed checksums when installation provenance matters.

## Validation

From `/usr/local/bin/proton_project`:

```bash
./bats-core/bin/bats tests
shellcheck ./*.sh tools/*.sh
bash -n ./*.sh tools/*.sh
git diff --check
```

Fleet gates:

```bash
/usr/local/bin/proton/proton-qbt-fleet-verify.sh --static-only
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --config
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

The `--recreate` command performs final runtime verification. Do not append a separate newline-delimited verifier as a substitute for checking its exit status.

## Documentation Map

- Architecture and invariants: `docs/architecture/qbittorrent-fleet-contract.md`
- Port synchronization: `docs/runbooks/qbittorrent-port-sync.md`
- Shared fleet changes: `docs/runbooks/qbittorrent-fleet-changes.md`
- Kernel/storage wedge recovery: `docs/runbooks/qbittorrent-wedge-recovery.md`
- Sonarr incident record: `docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md`

Keep historical evidence intact, but add dated recovery updates when operational status changes. Avoid hard-coded documentation or test line totals that become stale after ordinary edits.
