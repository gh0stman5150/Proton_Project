# Proton WireGuard Routing and qBittorrent Port Forwarding

This repository implements and maintains a host level Proton WireGuard routing design for Docker hosted application services.

## Policy and Authority

`copilot-instructions.md` is the source of truth for this repository.

This README documents the active implementation, runtime behavior, installation flow, and validation steps. If this README and `copilot-instructions.md` ever differ, follow `copilot-instructions.md`.

## Required Behavior

The repository must enforce the following rules:

1. All Docker hosted application traffic must use the Proton WireGuard VPN
2. SSH on `tcp/22` must bypass the VPN and remain reachable through WAN and LAN
3. RDP on `tcp/3389` must bypass the VPN and remain reachable through WAN and LAN
4. qBittorrent must automatically update its listening port whenever Proton's forwarded port changes or the VPN reconnects
5. qBittorrent must never bind or fall back to a non VPN path
6. Docker hosted application traffic must not leak directly to WAN during VPN downtime
7. DNS queries from Docker hosted application services must follow the intended VPN path and must not bypass the kill switch

## Network Model

This host is single homed on one Ethernet interface.

The intended routing model is:

1. SSH and RDP run on bare metal
2. SSH and RDP bypass the VPN for both inbound and outbound traffic
3. Docker hosted application services use the WireGuard path
4. Docker hosted application services must not leak directly to WAN if the VPN drops
5. The kill switch only needs to protect Docker hosted application traffic
6. Host traffic outside Docker does not need to be blocked by the kill switch unless explicitly required elsewhere

Do not replace this design with a VPN container, gateway container, or sidecar unless the repository already depends on that model and the reason is documented.

## Active Service Path

The systemd units are wired to the hardened entrypoints below:

1. `proton-killswitch-dispatch.sh`
2. `proton-killswitch-safe.sh`
3. `proton-killswitch-nft.sh`
4. `proton-wg-up-safe.sh`
5. `proton-wg-down-safe.sh`
6. `proton-port-forward-safe.sh`
7. `proton-qbittorrent-sync-safe.sh`
8. `proton-server-manager.sh`
9. `proton-healthcheck.sh`
10. `install-proton-systemd.sh`

Older scripts remain in the repository for reference only and must not be treated as the active service path.

The kill switch dispatcher defaults to `KILLSWITCH_BACKEND=auto`. It prefers `nftables` when `nft` is available and falls back to `iptables` otherwise.

`proton-docker-watch.service` is optional. See the Optional Docker Network Watcher section for when to enable it.

Do not rename, consolidate, or remove any script listed here without explicit instruction.

## Services in Scope

The following services are in scope for this routing and operational design:

1. qBittorrent
2. SABnzbd
3. Lidarr
4. Radarr
5. Sonarr
6. Whisparr
7. Bazarr
8. Prowlarr
9. Huntarr
10. Reaparr
11. Flaresolverr
12. Autobrr
13. Plex
14. Overseerr or Seer

Prometheus is no longer used and is not in scope for this repository.

## Required qBittorrent Env File

The installer copies `proton-qbittorrent.env` to `/etc/proton/qbittorrent.env` and keeps it root owned with mode `600`.

Minimum required variables:

```bash
QBITTORRENT_URL=http://127.0.0.1:8081
QBITTORRENT_USER=change-me
QBITTORRENT_PASS=change-me
```

Optional qB orchestration variables:

```bash
QBT_PORT_APPLY_MODE=compose-recreate
QBT_COMPOSE_PROJECT_DIR=
QBT_COMPOSE_SERVICE=qbittorrent
QBT_PORT_ENV_FILE=/etc/proton/qbittorrent-port.env
# Legacy DNAT mode only:
QBT_CONTAINER_NAME=qbittorrent
QBT_INTERNAL_PORT=6881
QBT_NETWORK_NAME=starr
```

The hardened path expects:

1. File path: `/etc/proton/qbittorrent.env`
2. Owner: `root`
3. Mode: `600`

## qBittorrent Port Update Behavior

When Proton assigns a new forwarded port, the default compose-recreate path must:

1. Detect the new forwarded port automatically
2. Update the qBittorrent listening port automatically
3. Update `QBT_PORT_ENV_FILE` which defaults to `/etc/proton/qbittorrent-port.env`
4. Recreate the qBittorrent Compose service only when the published port changes
5. Do not recreate the qBittorrent container if the forwarded port is unchanged from the published-port artifact
6. Verify that qBittorrent is listening on the expected port after the recreate path completes
7. Keep legacy host-side DNAT support only when `QBT_PORT_APPLY_MODE=legacy-dnat`
8. Confirm that qBittorrent remains bound only to the intended VPN path

`QBITTORRENT_URL` should point to the host published qBittorrent Web UI endpoint. Host systemd services cannot assume direct reachability to Docker network names unless that path is explicitly published or proxied.

## Install

Run the installer from the project bundle directory that contains the scripts, service files, and environment templates together.

Example:

```bash
cd /path/to/project-bundle
sudo ./install-proton-systemd.sh
```

The installer:

1. Copies the active Proton scripts to `/usr/local/bin/proton`
2. Copies the systemd unit files to `/etc/systemd/system`
3. Copies environment templates to `/etc/proton`
4. Secures the active WireGuard config as `root:root` with mode `600`
5. Preserves an existing `/etc/proton/qbittorrent.env`
6. Writes replacement templates to `*.new` files instead of overwriting secrets
7. Runs `systemctl daemon-reload`
8. Enables and restarts the Proton services

You can also pass qBittorrent credentials during install:

```bash
cd /path/to/project-bundle
sudo ./install-proton-systemd.sh \
  --qb-url http://127.0.0.1:8081 \
  --qb-user your-user \
  --qb-pass your-pass
```

You may also set Docker related values at install time:

```bash
cd /path/to/project-bundle
sudo ./install-proton-systemd.sh \
  --qb-container qbittorrent \
  --qb-int-port 6881 \
  --qb-network starr
```

After the base install, you may optionally enable `proton-docker-watch.service` if your Docker network CIDR or qBittorrent container IP can change over time.

## Runtime State

Live state is stored under `/run/proton`:

1. `/run/proton/proton-port.state`
2. `/run/proton/qbt-port.cache`
3. `/run/proton/docker-network-cidr`
4. `/run/proton/current-server.env`
5. `/run/proton/bad-servers.tsv`
6. `/run/proton/reselect-server.flag`
7. `/run/proton/recovery.lock`

Do not store live state files in the repository.

State under `/run/proton` must be treated as runtime data only and must be recreated safely across service restart, VPN reconnect, and host reboot events.

## Server Pool and Latency Selection

If `/etc/wireguard/proton-pool` contains one or more `*.conf` files, the active path treats that directory as a rotation pool. Reconnect or bad node recovery may select the lowest latency candidate by probing the endpoint IP from each config.

The selector stores the active choice in `/run/proton/current-server.env` and tracks cooldowns in `/run/proton/bad-servers.tsv`. It uses hysteresis so the current server is kept unless a replacement is meaningfully better or the current server is degraded.

By default the selector lints each candidate before selection. It rejects configs that contain `PreUp`, `PostUp`, `PreDown`, `PostDown`, or `SaveConfig`, and it expects `DNS` to match `WG_EXPECTED_DNS` unless `WG_LINT_ALLOW_MISSING_DNS=on`.

Useful knobs:

1. `WG_POOL_DIR=/etc/wireguard/proton-pool`
2. `SERVER_POOL_ENABLED=auto`
3. `BAD_SERVER_COOLDOWN=900`
4. `SERVER_SWITCH_MIN_IMPROVEMENT_MS=10`
5. `SERVER_SWITCH_DEGRADED_LATENCY_MS=75`
6. `PING_TIMEOUT_SECONDS=1`
7. `PING_COUNT=1`
8. `SERVER_POOL_STRICT_LINT=on`
9. `WG_EXPECTED_DNS=10.2.0.1`
10. `WG_LINT_ALLOW_MISSING_DNS=off`

Manual helpers:

1. `proton-server-manager.sh select`
2. `proton-server-manager.sh current`
3. `proton-server-manager.sh mark-bad <profile> <reason>`
4. `proton-server-manager.sh show-bad`
5. `proton-server-manager.sh reset-bad`

Any server rotation logic must preserve the repository routing rules, kill switch behavior, qBittorrent port synchronization, and DNS policy after reconnect.

## WireGuard Defaults

The units currently default to values such as:

1. `WG_PROFILE=proton`
2. `VPN_INTERFACE=proton`
3. `NATPMP_GATEWAY=10.2.0.1`
4. `MANAGEMENT_ALLOWED_CIDRS=<LAN_CIDR>,<YOUR_WAN_IP>/32`
5. `MANAGE_RESOLVED_DNS=auto`
6. `RESOLVED_DNS_ROUTE_DOMAIN=~.`

Set real values in environment files, not in committed documentation.

If your WireGuard profile or interface uses different names, update the environment files consumed by:

1. `proton-killswitch.service`
2. `proton-wg.service`
3. `proton-port-forward.service`
4. `proton-healthcheck.service`

IPv6 is intentionally not managed by the current kill switch path because it is disabled in the active Proton WireGuard profile.

## DNS Policy

The repository source of truth requires:

1. `1.1.1.1` as the primary upstream DNS resolver
2. `9.9.9.9` as the secondary upstream DNS resolver
3. Docker hosted application DNS queries must follow the intended VPN path
4. Docker hosted application DNS must not bypass the kill switch

When `MANAGE_RESOLVED_DNS=auto` and `resolvectl` is available, the up and down scripts may program and revert interface DNS. Treat that behavior as implementation detail, not policy by itself.

`WG_EXPECTED_DNS=10.2.0.1` is the WireGuard interface DNS provided by Proton inside the tunnel. The `1.1.1.1` and `9.9.9.9` values are external upstream resolvers used for DNS policy verification and are not substitutes for the tunnel DNS.

Do not assume DNS is correct only because WireGuard profile DNS values exist. Verify DNS behavior for:

1. host resolver configuration
2. container `/etc/resolv.conf`
3. Docker embedded DNS behavior
4. WireGuard DNS settings
5. any `systemd-resolved` integration
6. VPN down and reconnect events
7. container restarts

## Docker Egress Policy

Docker hosted application traffic must be constrained by the host level WireGuard and policy routing design defined by this repository.

Do not treat Docker egress control as optional or external to the repository architecture.

VPN bound containers must not be able to reach WAN directly outside the intended WireGuard path.

## Healthcheck

`proton-healthcheck.service` watches qBittorrent only when there are active transfers. If combined download and upload throughput stays below the configured threshold for multiple checks, the recovery ladder is:

1. qBittorrent port and DNAT refresh
2. One shot NAT PMP refresh
3. Bad server mark plus Proton service restart

The healthcheck and port forward loop share `RECOVERY_LOCK_FILE` so they do not trigger overlapping reconnect storms.

Default thresholds:

1. `CHECK_INTERVAL=60`
2. `MIN_COMBINED_SPEED_BPS=65536` which is 64 KB/s
3. `MAX_LOW_SPEED_CHECKS=3`

Tune those values in `proton-healthcheck.service` if the workload is bursty or often idle between peer activity.

Any healthcheck driven recovery must preserve:

1. Host level WireGuard routing
2. Docker application kill switch behavior
3. SSH and RDP bypass behavior
4. qBittorrent port correctness
5. DNS routing correctness

## Quick Verification

If you customized the defaults, source the relevant files under `/etc/proton` first or substitute the resolved values directly in the commands below.

### WireGuard and routing

```bash
wg show
ip rule show
ip route show table 51820
ip route show
```

### Firewall and kill switch

If the active backend is `nftables`:

```bash
sudo nft list table inet proton
sudo nft list table ip proton_nat
```

If the active backend is `iptables`, inspect the dedicated Proton chains and any policy routing related rules explicitly.

### qBittorrent state and mapping

If the active mode is `compose-recreate`:

```bash
cat /run/proton/proton-port.state
cat /run/proton/qbt-port.cache
cat /etc/proton/qbittorrent-port.env
```

If the active mode is `legacy-dnat`:

```bash
cat /run/proton/proton-port.state
cat /run/proton/qbt-port.cache
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' qbittorrent
sudo nft list chain ip proton_nat prerouting -a | grep qbt-dnat
```

### DNS behavior

Verify:

1. host resolver configuration
2. container `/etc/resolv.conf`
3. Docker DNS behavior
4. DNS path during VPN up, VPN down, and reconnect events

### Leak prevention

Confirm all of the following:

1. Docker hosted application traffic uses the VPN path
2. Docker hosted application traffic is blocked from direct WAN egress during VPN downtime
3. SSH and RDP remain reachable through WAN and LAN
4. qBittorrent remains bound only to the intended VPN path

### Safe failure test

```bash
sudo ip link set dev proton down
# verify Docker hosted application traffic is blocked from leaking
# verify SSH and RDP remain reachable as intended
sudo ip link set dev proton up
```

After recovery, recheck:

```bash
wg show
ip rule show
ip route show table 51820
```

## Optional Docker Network Watcher

If qBittorrent or other Docker hosted application services run on a bridged Docker network and routing depends on Docker network CIDR or container IP discovery, enable the watcher service to keep routing and DNAT in sync with Docker events.

The watcher listens for Docker network and container events and can:

1. Reapply Docker source-routing and raw-table return rules when the Docker network subnet changes
2. Reapply the Docker kill-switch state after Docker restarts or network changes
3. Refresh qBittorrent port state so compose-recreate or legacy-DNAT mode stays in sync

Install and start the watcher:

```bash
cd /path/to/project-bundle
sudo ./install-proton-systemd.sh
sudo systemctl daemon-reload
sudo systemctl enable --now proton-docker-watch.service
sudo journalctl -fu proton-docker-watch.service
```

Verify watcher behavior:

```bash
ip rule show | grep 51820
ip route show table 51820
sudo nft list chain ip proton_nat prerouting -a | grep qbt-dnat
```

Disable the watcher if not needed:

```bash
sudo systemctl disable --now proton-docker-watch.service
```

## Archive Analysis Requirement

Any significant routing, firewall, reconnect, qBittorrent sync, or Docker networking change must compare the active implementation with `/archive`.

That comparison must explain:

1. What the archived implementation did differently
2. Why it worked initially
3. Why it became unstable over time

Look specifically for:

1. Race conditions
2. Route leaks
3. DNS leaks
4. Firewall state drift
5. Stale policy routing
6. Reconnect edge cases
7. Docker and systemd ordering problems

If `/archive` is absent or empty, note that explicitly and proceed without archive comparison.

## Security Notes

1. Keep WireGuard and qBittorrent credential files root owned and mode `600`
2. Do not overwrite existing secrets during reinstall or upgrade
3. Avoid storing Proton credentials or other sensitive values in plaintext unless the risk is documented and accepted
4. Keep service privileges, mounts, and capabilities to the minimum required
5. Do not expose Docker hosted application services to WAN outside the intended design
6. Log enough information to debug reconnect, routing, firewall, and port forwarding failures without logging secrets

## Evidence and Change Standard

When evaluating or changing this repository:

1. Do not speculate without workspace evidence
2. Separate confirmed findings from hypotheses
3. Do not claim root cause without file evidence, command output, or reproducible behavior
4. Be explicit about whether the active firewall control plane is `iptables` or `nftables`
5. Do not mix `iptables` and `nftables` in recommendations unless the existing repository already depends on both and the interaction is explained clearly

