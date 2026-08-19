# qBittorrent/Proton operations documentation

This directory documents the five-instance qBittorrent fleet, its Proton port-forwarding control plane, and the 2026-08-14 Sonarr kernel/CIFS incident.

The canonical source is `/usr/local/bin/proton_project`. Do not use `/opt/proton_project_work` as current source unless it has been explicitly synchronized and verified.

## Current recovered baseline

- The live SMB 3.1.1 `/mnt/data` mount uses `cache=none` for all five clients and every other consumer of the share. The 2026-08-17 oops at 19:05 preceded the 20:01 fstab edit and 20:16 activation reboot; the mitigation has no observed recurrence yet, but it is not a demonstrated kernel fix.
- Both NAS mount units require the route-and-TCP-445 `nas-network-online.service` gate. Docker wants and follows all five Proton WireGuard units; the kill switch and runtime verifier remain independent safety gates.
- All five clients passed post-boot runtime verification with uploading and seeding enabled. Do not add torrent queueing, active-upload limits, seeding limits, or a Sonarr-only storage policy during follow-up work.
- Ubuntu `7.0.0-30.30` has no relevant netfs change; `7.0.0-31.31` is proposed-only; Linux 7.1.8 and 7.2 contain related but unproven repairs. Use the incident record and wedge runbook before changing kernels.

## Start here

| Document | Use it when |
| --- | --- |
| [Fleet architecture and invariants](architecture/qbittorrent-fleet-contract.md) | deciding what is shared, what is instance-specific, and which source is authoritative |
| [Port synchronization runbook](runbooks/qbittorrent-port-sync.md) | diagnosing or validating a Proton lease, qBittorrent listen port, or Docker TCP/UDP mapping |
| [Fleet change runbook](runbooks/qbittorrent-fleet-changes.md) | changing Compose, image, init hooks, orchestration code, routing, storage policy, or common qBittorrent settings |
| [Wedge recovery runbook](runbooks/qbittorrent-wedge-recovery.md) | a qBittorrent container is unhealthy, cannot stop, contains a zombie, or has a task in kernel `D` state |
| [2026-08-14 Sonarr incident report](incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md) | reviewing the evidence, timeline, root-cause assessment, impact, and corrective actions for this incident |

## Core operational rule

**Change one, change all** applies to shared service policy and behavior. A change to the qBittorrent image, common Compose policy, health check, init hook, storage strategy, port synchronizer, route logic, kill switch, allocator, or fleet-controlled qBittorrent preference must be implemented once and rolled through all five instances.

It does not mean copying runtime values. Lidarr, Prowlarr, Radarr, Sonarr, and Whisparr have independent WireGuard identities and independent Proton NAT-PMP leases. A new lease recreates only the qBittorrent container that owns it.

## Verification commands

```bash
# Safe, non-secret static contract
/usr/local/bin/proton/proton-qbt-fleet-verify.sh --static-only

# Static plus protected per-instance configuration
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --config

# Complete lease/artifact/container/API port and health parity
sudo /usr/local/bin/proton/proton-qbt-fleet-verify.sh --runtime
```

For a shared container/configuration rollout:

```bash
cd /usr/local/bin/proton_project &&
sudo ./install-proton-systemd.sh &&
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

The reconciler performs final runtime verification itself. Keep dependent commands joined with `&&` so a later verifier cannot mask an earlier failure. The tool refuses unhealthy or zombie members immediately and rejects a persistent same-LWP `D` state after multiple samples; a one-snapshot CIFS wait is allowed to clear.
