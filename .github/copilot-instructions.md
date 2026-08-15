# Copilot Instructions: Proton WireGuard Routing and qBittorrent Port Forwarding

## Authority

This file is the source of truth for this repository. Follow these requirements even if the current repository state differs.

## Goal

Implement and maintain a stable routing design with these rules:

1. All Docker hosted application traffic must use the Proton WireGuard VPN
2. SSH on `tcp/22` must bypass the VPN and remain reachable through WAN and LAN
3. RDP on `tcp/3389` must bypass the VPN and remain reachable through WAN and LAN
4. qBittorrent must automatically update its listening port when Proton's forwarded port changes or the VPN reconnects
5. qBittorrent must never bind or fall back to a non VPN path

## Environment

1. The host is single homed on one Ethernet interface
2. SSH and RDP run on bare metal
3. SSH and RDP must bypass the VPN for both inbound and outbound traffic
4. The kill switch only needs to protect Docker hosted application traffic
5. Host traffic outside Docker does not need to be blocked by the kill switch

## Required Design

1. Use host level WireGuard with policy routing
2. Do not introduce a VPN container, gateway container, or sidecar unless the repo already depends on it and the reason is documented from workspace evidence
3. Docker hosted application traffic must use WireGuard
4. Docker hosted application traffic must not leak to WAN if the VPN drops
5. Preserve intended LAN access for services such as Plex and Overseerr without creating unintended WAN bypass paths

## Services in Scope

qBittorrent, NZBget, Lidarr, Radarr, Sonarr, Whisparr, Bazarr, Prowlarr, Reaparr, Flaresolverr, Autobrr, Cross-Seed, Profilarr, Qui, Quickstart, Upbrr, Plex, Seer

## Inspect First

Before changing anything, inspect:

1. WireGuard configs such as `wg0.conf`, Proton configs, related scripts, and systemd units
2. Firewall rules and determine whether the active control plane is `iptables` or `nftables`
3. Routing state with `ip rule` and `ip route`
4. Docker Compose files, Docker networks, published ports, namespaces, and capabilities
5. Healthchecks, watchdogs, reconnect logic, cron jobs, and systemd timers
6. qBittorrent port updater scripts, NAT-PMP refresh flow, and any Compose-fed published-port inputs
7. Host and container DNS configuration
8. Anything under `/archive`

## Archive Requirement

Compare the current implementation with `/archive`.

Explain:

1. What the archived version did differently
2. Why it worked at first
3. Why it became unstable over time

Look for:

1. Race conditions
2. Route leaks
3. DNS leaks
4. Firewall state drift
5. Stale policy routing
6. Reconnect edge cases
7. Docker and systemd ordering problems

If `/archive` is absent or empty, say so explicitly and proceed without archive-based root-cause claims.

## Network Rules

### Routing

1. Force Docker hosted application traffic through WireGuard
2. Keep SSH and RDP on the normal non VPN route
3. Keep SSH and RDP on the normal route for both inbound and outbound traffic
4. Document exactly how traffic is classified and enforced

### Kill Switch

1. Block Docker hosted application traffic from reaching WAN outside the VPN
2. Do not block unrelated host traffic
3. SSH and RDP must continue to work during VPN downtime

### Docker Isolation

1. VPN bound containers must not reach WAN directly
2. Use explicit Docker networks with host level routing and firewall enforcement
3. Do not allow mixed or ambiguous egress paths
4. Note any service using host networking and explain its impact

## qBittorrent Rules

1. Detect Proton forwarded port changes automatically
2. Update the qBittorrent listening port automatically
3. Store the last applied mapping in `/etc/proton/instances/<instance>/qbittorrent-port.env` as exactly one assignment, `QBT_PUBLISHED_PORT=<port>`; never write `QBT_FORWARDED_PORT` and never write a dynamic port to the Compose project `.env`
4. Because the published port mapping cannot change while the container is running, stop and recreate the qBittorrent container after the port value changes
5. Verify the new port after restart
6. Confirm qBittorrent is bound only to the intended VPN path
7. In compose-recreate mode, self-heal may recreate qBittorrent when the Web UI is unreachable, but it must refuse normal Compose work if the named container has lost its published ports, contains a zombie, or contains an uninterruptible `D`-state task
8. A refused self-heal must preserve the existing published-port artifact so runtime state does not drift while the wedged container still owns the Docker name.
9. Treat confirmed `D` state after a netfs/CIFS kernel fault as a host-kernel recovery boundary. Preserve evidence and require an approved host reboot; do not prescribe repeated signals, `cgroup.kill`, shim killing, forced removal, or Compose recreation as a repair.
10. A Proton lease change recreates only the qBittorrent service that owns that tunnel. Never copy one instance's port to another instance.
11. An unchanged lease normally does not recreate the container. A fleet structural change may set the documented force-recreate flag and must roll all five instances sequentially with health gates.

## qBittorrent Fleet Consistency

1. The managed instances are `lidarr`, `prowlarr`, `radarr`, `sonarr`, and `whisparr`.
2. `qbittorrent-compose.common.yml` is the single source for shared image, environment, volume, health-check, restart, shutdown, and network policy.
3. Each `/opt/qbittorrent-<instance>/docker-compose.yml` must remain a thin instance wrapper that extends the installed common service.
4. `qbittorrent-instances.tsv` is the canonical instance identity catalog. Do not repeat instance metadata in case statements or unscoped tests.
5. Every `/opt/qbittorrent-<instance>/.env` must contain exactly one assignment: its `QBT_HOST_BIND_IP`.
6. The allowed wrapper differences are service/container identity, Web UI port, bind IP, and instance-local config/init paths. Torrent ports have no Compose fallback and must be injected from the matching live Proton lease.
7. A change to shared Compose policy, image, init hook, storage strategy, synchronization code, route logic, kill switch, allocator, watcher, or fleet-controlled qBittorrent preference must be applied and verified on all five instances.
8. Dynamic leases, tunnel identities, runtime state, credentials, paths/categories, and documented role overrides remain per-instance.
9. Do not normalize qBittorrent by copying an entire `qBittorrent.conf`; classify common keys and explicit role overrides first.
10. A shared rollout must preflight the complete fleet, refuse before the first mutation if any member is absent/unhealthy/zombie/`D` state, recreate sequentially, and run the full runtime verifier at the end.
11. All shared policy-route mutations must use one host-global route lock. Both firewall backends must use one host-global kill-switch lock. These locks must not derive from an instance `STATE_DIR`.
12. No systemd `ExecStart` may target the source checkout. Installed entrypoints live under `/usr/local/bin/proton` and must be executable.

## DNS Rules

1. Use `1.1.1.1` as primary upstream DNS
2. Use `9.9.9.9` as secondary upstream DNS
3. Inspect host resolver configuration
4. Inspect container `/etc/resolv.conf`
5. Inspect Docker embedded DNS behavior
6. Inspect WireGuard DNS settings
7. Inspect any `systemd-resolved` integration
8. All DNS queries from Docker hosted application services must follow the intended VPN path
9. Docker hosted application DNS must not bypass the kill switch
10. Verify DNS during normal operation, VPN drops, reconnects, and container restarts

## Firewall Rule

1. Identify whether the system is using `iptables` or `nftables`
2. Do not mix them in recommendations unless the repo already depends on both and the interaction is explained clearly
3. Be explicit about which framework owns kill switch logic, forwarding, NAT, and persistence

## Evidence Rule

1. Do not speculate without workspace evidence
2. Separate confirmed findings from hypotheses
3. Do not claim root cause without file evidence, command output, or reproducible behavior

## Output Requirements

Begin every response with the key files found.

Then provide:

### 1. Repo Summary

A text based architecture diagram showing components and traffic flow

### 2. Findings

Show:

1. Where routing is defined
2. Where firewall rules are defined
3. Where Docker networking is defined
4. Where qBittorrent port forwarding is handled
5. Where leaks or instability can occur
6. How current and archived implementations differ

### 3. Root Cause Hypotheses

List likely causes of archived instability with evidence from exact files

### 4. Concrete Fixes

Provide:

1. Exact commands or config changes
2. File by file recommendations with full paths
3. Patch style snippets or exact lines to add, remove, or edit
4. Any systemd ordering, timer, or watchdog fixes

### 5. Verification Checklist

Include commands and steps to validate:

1. `ip rule`
2. `ip route`
3. `wg show`
4. `tcpdump`
5. DNS leak prevention
6. public IP leak prevention
7. qBittorrent port update behavior
8. VPN drop handling
9. VPN reconnect handling
10. kill switch activation and recovery
11. qBittorrent wedged-container guard behavior, including that self-heal refuses normal Compose recreation when a running container has no published ports
12. zombie and uninterruptible `D`-state refusal behavior
13. the one-key port artifact and all-five static/runtime fleet verification

### 6. Security Notes

Include:

1. Least privilege for containers
2. Secrets handling and plaintext credential risks
3. Logging guidance
4. Unnecessary privileges, mounts, or network exposure

## Response Style

1. Use headings
2. Cite exact workspace paths such as `./proton-qbittorrent-sync-safe.sh` and `./archive/<artifact-if-present>`
3. Present recommended changes as patch style snippets or exact edits
4. Be explicit about `iptables` versus `nftables`
5. If required files are missing, say so clearly
