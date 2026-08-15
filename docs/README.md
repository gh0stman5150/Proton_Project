# qBittorrent/Proton operations documentation

This directory documents the five-instance qBittorrent fleet, its Proton port-forwarding control plane, and the 2026-08-14 Sonarr kernel/CIFS incident.

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
sudo /usr/local/bin/proton/proton-qbt-fleet-reconcile.sh --recreate
```

Do not run the recreate command while any member is unhealthy, zombie, or in uninterruptible `D` state. The tool is designed to refuse before changing the first member in those conditions.
