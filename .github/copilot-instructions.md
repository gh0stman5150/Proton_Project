# Copilot Instructions: Proton WireGuard VPN Routing & qBittorrent Port Forwarding

## Goal

Implement a stable, secure routing design that forces all traffic through the Proton WireGuard VPN, with the following exceptions:

- **SSH (tcp/22)** must bypass the VPN and remain reachable via WAN/LAN
- **RDP (tcp/3389)** must bypass the VPN
- Everything else, including all media stack services, must route through the VPN

Additionally, qBittorrent must automatically update its listening port whenever Proton's forwarded port changes or when the VPN reconnects.
When the listening port is updated, the qBittorrent container must be taken down and restarted to apply the new port.

---

## Stack Services in Scope

qBittorrent, SABnzbd, Lidarr, Radarr, Sonarr, Whisparr, Bazarr, Prowlarr, Huntarr, Reaparr, Flaresolverr, Autobrr, Plex, Overseerr/Seer

---

## What to Inspect First

Before making any changes, locate and analyze the following:

- WireGuard configs: `wg0.conf`, Proton-provided configs, any related scripts and systemd units
- Firewall rules: iptables or nftables rulesets, routing tables, and policy routing (`ip rule`, `ip route`)
- Docker Compose files, container networking configs, namespaces, and capabilities
- Healthchecks, watchdogs, reconnection logic, and any cron or systemd timers
- qBittorrent port-forward updater scripts, including how they authenticate with Proton

### Pay Special Attention to `/archive`

- Identify what the archived implementation did differently from the current one
- Explain why it worked initially but became unstable after extended uptime
- Call out any race conditions, leaking routes, DNS issues, firewall state drift, or reconnect edge cases

---

## Key Technical Requirements

### A) Split Tunneling and Policy Routing

- Force the default route for all stack traffic through the WireGuard interface
- Ensure SSH and RDP bypass the VPN using policy routing (source-based, fwmark-based, or interface-based)
- Implement a kill-switch to prevent traffic leaks during VPN downtime
- Handle DNS correctly: prevent DNS leaks and ensure containers resolve reliably

### B) Docker and Service Isolation

- Ensure VPN-bound containers cannot reach WAN directly
- Prefer one of the following isolation approaches:
  - A network namespace or dedicated VPN gateway container
  - Explicit Docker networks routing through a single egress point
- Ensure Plex and Overseerr remain accessible from the LAN as intended

### C) qBittorrent Dynamic Port Handling

- Detect Proton forwarded port changes and apply them to qBittorrent automatically
- Ensure port updates survive container restarts and VPN reconnects
- Confirm qBittorrent is bound to the VPN interface and cannot fall back to a non-VPN binding

---

## Expected Deliverables

When analyzing this repo, produce the following:

1. **Repo Summary** — A text-based architecture diagram showing components and traffic flow

2. **Findings**
   - Where routing and firewall rules are established
   - Where leaks or instability can occur
   - Differences between the current and archived implementation

3. **Root-Cause Hypotheses** for archived instability, with evidence cited from specific files

4. **Concrete Fixes**
   - Exact commands or config changes
   - File-by-file recommendations with full paths (e.g., `./scripts/...`, `./archive/...`)
   - Improved systemd unit, timer, or watchdog suggestions where applicable

5. **Verification Checklist**
   - Commands to validate routing: `ip rule`, `ip route`, `wg show`, `tcpdump`
   - Leak tests covering both DNS and IP
   - Steps to simulate a VPN drop and reconnect, and confirm the kill-switch activates correctly

6. **Security Notes**
   - Least privilege principles for capabilities and container permissions
   - Secrets handling: avoid storing credentials in plaintext
   - Logging guidance: what to log and what must not be logged

---

## Output Format Requirements

- Use headings and bullets throughout
- Cite exact filenames and paths from the workspace (e.g., `./scripts/update-port.sh`, `./archive/wg0.conf`)
- Present recommended changes as patch-style snippets or exact lines to add or edit
- Be explicit about whether rules are `iptables` or `nftables`; do not mix them unless the reasoning is clearly justified
- Begin every response by listing the key files found before proceeding with analysis
