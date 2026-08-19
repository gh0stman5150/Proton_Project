#!/usr/bin/env bats

@test "README keeps archive analysis conditional" {
  run grep -F 'If `/archive` is absent or empty, note that explicitly and proceed without archive comparison.' README.md
  [ "$status" -eq 0 ]
}

@test "AGENTS instructions keep archive analysis conditional" {
  run grep -F 'If `/archive` is absent or empty, say so explicitly and proceed without archive-based root-cause claims.' AGENTS.md
  [ "$status" -eq 0 ]
}

@test "copilot instructions point to the AGENTS authority" {
  run grep -F 'The authoritative project instructions are in `../AGENTS.md`.' .github/copilot-instructions.md
  [ "$status" -eq 0 ]
}

@test "documentation identifies the canonical source and stale working copy" {
  grep -Fq 'The canonical source repository is `/usr/local/bin/proton_project`.' AGENTS.md
  grep -Fq 'Treat `/opt/proton_project_work` as a non-authoritative working copy that may be stale.' AGENTS.md
  grep -Fq 'The canonical source is `/usr/local/bin/proton_project`.' docs/README.md
}

@test "fleet docs distinguish transient and persistent D state" {
  grep -Fq 'A single `D`-state snapshot can be normal transient CIFS I/O.' AGENTS.md
  grep -Fq 'Automation samples LWP IDs and refuses recreation only when the same task remains uninterruptible across the configured samples.' docs/architecture/qbittorrent-fleet-contract.md
  grep -Fq 'transient `D` state: sample the LWP and proceed only after it clears;' docs/runbooks/qbittorrent-port-sync.md
}

@test "fleet docs require forced lock completion and failure-preserving activation" {
  grep -Fq 'Forced fleet sync waits for the lock and fails on timeout' AGENTS.md
  grep -Fq 'It must never report a skipped instance as a successful structural rollout.' docs/architecture/qbittorrent-fleet-contract.md
  grep -Fq 'Keep dependent commands joined with `&&`' README.md
}

@test "incident report records recurrence, recovery, and mitigation ordering" {
  grep -Fq 'the host reboot completed on 2026-08-15' docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md
  grep -Fq '2026-08-16 09:04:04 CDT' docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md
  grep -Fq 'the third reboot completed on 2026-08-17' docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md
  grep -Fq 'Both CIFS mounts now require a successful route and SMB socket check' docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md
  grep -Fq '2026-08-17 19:05:07 CDT' docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md
  grep -Fq 'Torrent queueing remained disabled. No active-upload or seeding limit was introduced.' docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md
  grep -Fq 'This is one mount-level policy for all five qBittorrent instances, not a Sonarr-only override.' docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md
  grep -Fq 'This ordering proves that the 19:05 oops preceded the mitigation.' docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md
  grep -Fq 'the first live `/mnt/data` mount with `cache=none`' docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md
  grep -Fq 'Do not deploy local incomplete directories on this host without adding capacity for the whole fleet.' docs/runbooks/qbittorrent-wedge-recovery.md
}

@test "canonical docs record cache=none as the active shared mitigation" {
  grep -Fq 'The live SMB 3.1.1 `/mnt/data` mount uses `cache=none`.' AGENTS.md
  grep -Fq '`/mnt/data` is an SMB 3.1.1 CIFS mount with active `cache=none`.' README.md
  grep -Fq 'The live SMB 3.1.1 `/mnt/data` mount uses `cache=none` for all five clients' docs/README.md
  grep -Fq 'The active fstab entry and live `/mnt/data` mount use `cache=none`.' docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md
  grep -Fq 'The capacity-independent mitigation is active:' docs/runbooks/qbittorrent-wedge-recovery.md
}

@test "canonical docs preserve uploading and seeding availability" {
  grep -Fq 'Keep uploading and seeding enabled.' AGENTS.md
  grep -Fq 'recovery introduced no active-upload or seeding limit.' README.md
  grep -Fq 'Do not globally pause torrents or add queueing, active-upload, or seeding limits' docs/architecture/qbittorrent-fleet-contract.md
  grep -Fq 'Keep uploading and seeding enabled.' docs/runbooks/qbittorrent-fleet-changes.md
  grep -Fq 'Their uploads and seeding remain active.' docs/runbooks/qbittorrent-port-sync.md
}

@test "canonical docs record NAS and Proton before Docker ordering" {
  grep -Fq '`mnt-data.mount` and `mnt-plex.mount` require and follow `nas-network-online.service`' AGENTS.md
  grep -Fq 'Docker wants and follows all five Proton WireGuard units.' README.md
  grep -Fq 'Both NAS mount units require the route-and-TCP-445 `nas-network-online.service` gate.' docs/README.md
  grep -Fq 'Docker wants and follows all five `proton-wg@<instance>.service` units.' docs/runbooks/qbittorrent-wedge-recovery.md
}

@test "kernel guidance distinguishes related repairs from a proven fix" {
  grep -Fq 'Ubuntu `7.0.0-30.30` has no relevant netfs change' AGENTS.md
  grep -Fq '`7.0.0-31.31` remains proposed-only' README.md
  grep -Fq 'Linux 7.1.8 contains later writeback error and `ENOMEM` iteration-state repairs' docs/incidents/2026-08-14-qbittorrent-sonarr-cifs-netfs-wedge.md
  grep -Fq 'The latter changes are relevant but do not prove prevention of this exact `netfs_read_gaps` oops.' docs/runbooks/qbittorrent-wedge-recovery.md
}
