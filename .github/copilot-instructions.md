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

qBittorrent, SABnzbd, Lidarr, Radarr, Sonarr, Whisparr, Bazarr, Prowlarr, Huntarr, Reaparr, Flaresolverr, Autobrr, Plex, Overseerr or Seer

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
3. Update the Docker Compose value or the file that feeds it
4. Because the published port mapping cannot change while the container is running, stop and recreate the qBittorrent container after the port value changes
5. Verify the new port after restart
6. Confirm qBittorrent is bound only to the intended VPN path

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
