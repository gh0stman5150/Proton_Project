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

`proton-docker-watch@INSTANCE.service` is optional. See the Optional Docker Network Watcher section for when to enable it.

Do not rename, consolidate, or remove any script listed here without explicit instruction.

## Services in Scope

The following services are in scope for this routing and operational design:

1. qBittorrent
2. NZBget
3. Lidarr
4. Radarr
5. Sonarr
6. Whisparr
7. Bazarr
8. Prowlarr
9. Cross-seed
10. Reaparr
11. Flaresolverr
12. Autobrr
13. Plex
14. Seer
15. Mousehole
16. Profilarr
17. Soularr
18. Upbrr

Prometheus is no longer used and is not in scope for this repository.

## Required qBittorrent Env File

The installer copies `proton-qbittorrent.env` to `/etc/proton/qbittorrent.env` and keeps it root owned with mode `600`.

Minimum required variables:

```bash
QBITTORRENT_URL=http://192.168.237.78:8081
QBITTORRENT_USER=change-me
QBITTORRENT_PASS=change-me
```

Optional qB orchestration variables:

```bash
QBT_PORT_APPLY_MODE=compose-recreate
QBT_RESPECT_MANUAL_STOP=1
QBT_MANUAL_STOP_EVENT_GRACE_SECONDS=180
QBT_COMPOSE_PROJECT_DIR=/opt/qbittorrent
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

## Named qBittorrent Instances

The templated service path supports one Proton/qBittorrent failure domain per workload. Supported instance names are:

1. `lidarr`
2. `radarr`
3. `sonarr`
4. `whisparr`
5. `prowlarr`

Use `prowlarr` for manual downloads. Prowlarr itself can still manage indexers normally; this instance is the dedicated qBittorrent target for one-off/manual releases.

The installer creates example files under `/etc/proton/instances/<instance>/`:

1. `proton.env.example`
2. `qbittorrent.env.example`

Copy those to `proton.env` and `qbittorrent.env`, then keep real config files root owned with mode `600`. The generated defaults use:

Each instance uses the same unique `qbittorrent-<instance>` value for both
`QBT_CONTAINER_NAME` and `QBT_COMPOSE_SERVICE`. This prevents Docker DNS alias
collisions on a shared network while allowing the port-forward synchronizer to
recreate the correct Compose service.

| Instance   | qBittorrent            | Web UI | Interface  | Tunnel subnet |
| ---        | ---                    | ---    | ---        | ---           |
| `lidarr`   | `qbittorrent-lidarr`   | `8081` | `pvlidarr` | `10.2.0.2/32` |
| `prowlarr` | `qbittorrent-prowlarr` | `8082` | `pvprowl`  | `10.6.0.2/32` |
| `radarr`   | `qbittorrent-radarr`   | `8083` | `pvradarr` | `10.3.0.2/32` |
| `sonarr`   | `qbittorrent-sonarr`   | `8084` | `pvsonarr` | `10.4.0.2/32` |
| `whisparr` | `qbittorrent-whisparr` | `8085` | `pvwhisp`  | `10.5.0.2/32` |

### Same Server and Multi Tunnel Isolation

The implementation must support five independent Proton connections even when multiple instances use the same Proton VPN server. Sharing a Proton server endpoint is allowed; sharing a tunnel identity, interface, qBittorrent target, runtime state, or forwarded-port artifact is not.

Proton's NAT-PMP forwards exactly one port per client tunnel address, not per server. Connecting five tunnels with the same client address (`10.2.0.2`) therefore returns the same forwarded port to every instance and the published host ports collide. Proton supports multiple simultaneous tunnels on a single account by giving each tunnel config a distinct client address subnet (`10.2.0.x`, `10.3.0.x`, ...), each with its own gateway/DNS (`10.2.0.1`, `10.3.0.1`, ...). Each distinct client address receives an independent forwarded port.

Each instance therefore sets `WG_ADDRESS_SUBNET=<n>` in its `proton.env`. The instance loader derives everything from it so the address, DNS, and NAT-PMP gateway can never drift apart:

1. `WG_TUNNEL_ADDRESS=10.<n>.0.2/32`
2. `WG_TUNNEL_DNS=10.<n>.0.1`
3. `NATPMP_GATEWAY=10.<n>.0.1`

The shared pool configs under `WG_POOL_DIR` keep their original `10.2.0.2/32` address for linting; only the per-instance runtime copy in `WG_RUNTIME_DIR` is rewritten to the instance subnet by `proton-wg-up-safe.sh`.

The local WireGuard interface name and runtime config path are keyed on the instance (`pv<inst>`), never on the selected server. Two instances may select the same Proton server, but they keep independent local interfaces and independent NAT-PMP requests. Server selection is serialized by a global lock so two instances never adopt the same pool config (same WireGuard key) concurrently, which Proton would otherwise collapse into a single session.

Each instance must define its own values:

```bash
INSTANCE_NAME=prowlarr
WG_PROFILE=pvprowl
VPN_INTERFACE=pvprowl
WG_CONFIG=/etc/proton/instances/prowlarr/wireguard.conf
WG_ADDRESS_SUBNET=6
STATE_DIR=/run/proton/prowlarr
QBT_PORT_ENV_FILE=/etc/proton/instances/prowlarr/qbittorrent-port.env
```

Each instance must use its own WireGuard identity, preferably generated as a separate Proton WireGuard config. Two configs may point at the same Proton server endpoint, but they still must be separate files with separate interface names, separate tunnel subnets, and separate runtime/service state.

The migration is not complete until tests explicitly prove:

1. `lidarr` and `radarr` may point to the same Proton server
2. `lidarr` and `radarr` still use different WireGuard interfaces
3. `lidarr` and `radarr` still write different forwarded-port state files
4. stopping `radarr` does not stop `lidarr`
5. restarting `prowlarr` does not change Sonarr's qBittorrent port
6. each instance derives a distinct tunnel subnet and NAT-PMP gateway from `WG_ADDRESS_SUBNET`

This is a core migration requirement, not a small config tweak. The final design needs multiple simultaneous Proton connections, multiple VPN interfaces, multiple qBittorrent env files, multiple port state files, templated service instances, and same-server isolation tests.

Start one instance first during migration:

```bash
sudo systemctl start proton-wg@prowlarr proton-port-forward@prowlarr proton-healthcheck@prowlarr
```

After Prowlarr manual downloads work and its qBittorrent listen port follows the Proton forwarded port, repeat the same pattern for Sonarr, Radarr, Lidarr, and Whisparr.

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
9. Refuse normal Compose self-heal if Docker still reports the named qBittorrent container as running but it has no published ports. That state means the container is wedged below the normal Compose control plane and another `docker compose up --force-recreate` will create short-ID orphans or Docker name conflicts instead of fixing the service.

The recommended artifact path is `/etc/proton/qbittorrent-port.env`. In compose-recreate mode the sync script injects `QBT_PUBLISHED_PORT` into `docker compose`, so the service does not need write access to the Compose project tree just to update the published port.

With `QBT_RESPECT_MANUAL_STOP=1`, the sync script treats an existing qBittorrent container in `created`, `exited`, `dead`, or `removing` state as intentionally stopped and skips compose recreation. It also treats recent Docker stop or network-disconnect events as a stop in progress for `QBT_MANUAL_STOP_EVENT_GRACE_SECONDS`, so a graceful qBittorrent shutdown is not mistaken for a wedged Web UI. Set `QBT_RESPECT_MANUAL_STOP=0` only if Proton should bring stopped qBittorrent containers back up automatically.

When the Web UI is unreachable at sync startup, compose-recreate mode attempts one self-heal recreate. Before doing so, it checks the current Docker container state. If the named qBittorrent container is still `running` but Docker reports no published ports, the script logs an error and exits without rewriting the published-port artifact and without running Compose. This protects the host from the qBittorrent/s6 shutdown wedge where the old container still owns the Docker name and each recreate attempt produces a new `<shortid>_qbittorrent-<instance>` orphan.

`QBITTORRENT_URL` should point to the host published qBittorrent Web UI endpoint. Host systemd services cannot assume direct reachability to Docker network names unless that path is explicitly published or proxied.

### qBittorrent Wedged-Container Recovery

The self-heal guard exists for this Docker state:

1. The named container, such as `qbittorrent-prowlarr`, is still `running`
2. Docker reports no published ports for that container
3. qBittorrent Web UI probes fail
4. `docker top` may show `qbittorrent-nox` as a zombie
5. Compose recreate attempts would fail with a Docker name conflict because the old container still owns `/qbittorrent-<instance>`

Diagnose the state with:

```bash
docker ps -a --filter 'name=qbittorrent-prowlarr' --format 'table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}'
docker inspect qbittorrent-prowlarr --format 'PID={{.State.Pid}} Health={{if .State.Health}}{{.State.Health.Status}}{{end}} Ports={{json .NetworkSettings.Ports}}'
docker top qbittorrent-prowlarr -eo pid,ppid,stat,wchan,cmd
journalctl --no-pager -u proton-port-forward@prowlarr.service -u proton-docker-watch@prowlarr.service --since '30 minutes ago' \
  | grep -E 'Web UI unreachable|self-heal|running with no published ports|name .* already in use|qBittorrent sync failed'
```

When the guard fires, stop the per-instance Proton automation before attempting cleanup:

```bash
sudo systemctl stop proton-port-forward@prowlarr.service proton-docker-watch@prowlarr.service
```

Try cgroup cleanup first, using the current container PID so the command targets the live stuck scope:

```bash
pid=$(docker inspect qbittorrent-prowlarr --format '{{.State.Pid}}')
cgroup=$(sed -n 's/^0:://p' "/proc/$pid/cgroup")
echo 1 | sudo tee "/sys/fs/cgroup${cgroup}/cgroup.kill"
```

If the cgroup remains populated and Docker still cannot remove the container, kill the per-container `containerd-shim` parent:

```bash
pid=$(docker inspect qbittorrent-prowlarr --format '{{.State.Pid}}')
shim=$(ps -o ppid= -p "$pid" | tr -d ' ')
sudo kill -9 "$shim"
```

Then remove stale containers, recreate the service with the current forwarded port, and restart automation:

```bash
docker rm -f qbittorrent-prowlarr 2>/dev/null || true
docker rm $(docker ps -aq --filter 'name=_qbittorrent-prowlarr') 2>/dev/null || true

cd /opt/qbittorrent-prowlarr
QBT_HOST_BIND_IP=10.6.0.2 QBT_PUBLISHED_PORT=54322 docker compose up -d --force-recreate --no-deps qbittorrent

sudo systemctl start proton-docker-watch@prowlarr.service proton-port-forward@prowlarr.service
```

Substitute the instance name, `QBT_HOST_BIND_IP`, Web UI port, and `QBT_PUBLISHED_PORT` for other qBittorrent instances. For prowlarr, the default VPN bind IP is `10.6.0.2` and the Web UI port is `8082`; the published torrent port must come from the active Proton state, not from the Compose fallback.

## Install

Run the installer from the project bundle directory that contains the scripts, service files, and environment templates together.

Example:

```bash
cd /path/to/project-bundle
sudo ./install-proton-systemd.sh
```

The installer:

1. Ensures the required Proton VPN Debian packages are installed, bootstrapping the Proton VPN apt repository and installing `protonvpn` if any are missing
2. Stops active Proton services first during a redeploy so old long-running processes do not survive the file copy
3. Copies the active Proton scripts to `/usr/local/bin/proton`
4. Copies the systemd unit files to `/etc/systemd/system`
5. Copies environment templates to `/etc/proton`
6. Secures the active WireGuard config as `root:root` with mode `600`
7. Preserves an existing `/etc/proton/qbittorrent.env`
8. Writes replacement templates to `*.new` files instead of overwriting secrets
9. Installs units that have systemd recreate `/run/proton` before applying sandboxed writable paths
10. Clears stale bad-server cooldowns, port-forward incapable state, port-forward incapability strikes, runtime selection state, and failed Proton service state before restart
11. Runs `systemctl daemon-reload`
12. Enables and restarts the Proton services
13. Restarts Docker watcher services only if they were already enabled

You can also pass qBittorrent credentials during install:

```bash
cd /path/to/project-bundle
sudo ./install-proton-systemd.sh \
  --qb-url http://192.168.237.78:8081 \
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

After the base install, you may optionally enable `proton-docker-watch@INSTANCE.service` if your Docker network CIDR or qBittorrent container IP can change over time.

## Upgrade and Redeploy

Re-running `install-proton-systemd.sh` is the preferred way to deploy script updates. The installer now resets stale runtime and selector state before restarting the Proton services so a patched rollout does not keep old cooldowns, old `port-forward incapable` marks, or a failed `proton-healthcheck.service` latched in place.

On a redeploy, the installer also stops active Proton services before replacing the scripts on disk. That avoids leaving an old `proton-port-forward.service`, `proton-healthcheck.service`, or watcher process alive while the new script bundle is being copied into place.

If you deploy files manually instead of using the installer, run the equivalent reset sequence yourself before restarting services:

```bash
sudo systemctl stop proton-docker-watch@prowlarr.service proton-healthcheck@prowlarr.service proton-port-forward@prowlarr.service proton-wg@prowlarr.service proton-killswitch.service || true
sudo /usr/local/bin/proton/proton-server-manager.sh reset-incapable
sudo /usr/local/bin/proton/proton-server-manager.sh reset-incapable-strikes
sudo /usr/local/bin/proton/proton-server-manager.sh reset-bad
sudo rm -f /run/proton/current-server.env /run/proton/proton-port.state /run/proton/recovery.lock
sudo systemctl reset-failed proton-docker-watch@prowlarr.service proton-healthcheck@prowlarr.service proton-port-forward@prowlarr.service proton-wg@prowlarr.service proton-killswitch.service
sudo systemctl restart proton-wg@prowlarr.service proton-port-forward@prowlarr.service proton-healthcheck@prowlarr.service
```

The manual sequence intentionally preserves `PF_CAPABLE_PROFILES_FILE` so the selector can keep its proven-good port-forward allowlist while relearning only the transient failure state.

## Runtime State

Live state is stored under `/run/proton`:

1. `/run/proton/proton-port.state`
2. `/run/proton/qbt-port.cache`
3. `/run/proton/docker-network-cidr`
4. `/run/proton/current-server.env`
5. `/run/proton/bad-servers.tsv`
6. `/run/proton/reselect-server.flag`
7. `/run/proton/recovery.lock`
8. `/run/proton/pf-incapable-strikes.tsv`

Do not store live state files in the repository.

State under `/run/proton` must be treated as runtime data only and must be recreated safely across service restart, VPN reconnect, and host reboot events.

## Server Pool and Latency Selection

If `/etc/wireguard/proton-pool` contains one or more `*.conf` files, the active path treats that directory as a rotation pool. Reconnect or bad node recovery may select the lowest latency candidate by probing the endpoint IP from each config.

The selector stores the active choice in `/run/proton/current-server.env` and tracks cooldowns in `/run/proton/bad-servers.tsv`. It uses hysteresis so the current server is kept unless a replacement is meaningfully better or the current server is degraded.

When `PORT_FORWARD_REQUIRED=on`, the pool also learns which profiles have actually returned a Proton forwarded port. Successful profiles are recorded in `PF_CAPABLE_PROFILES_FILE`, failed profiles can be recorded in `PF_INCAPABLE_PROFILES_FILE`, and the selector effectively treats the pool as three categories:

1. `proven-good` which are in `PF_CAPABLE_PROFILES_FILE`
2. `unproven` which are in neither file yet
3. `port-forward incapable` which are in `PF_INCAPABLE_PROFILES_FILE`

`port-forward incapable` remains a hard exclusion until the profile is proven again or the incapable state is reset. When the proven-good set is non-empty, the selector prefers those proven-good nodes first. If every proven-good node is temporarily cooling down or otherwise unavailable, the selector can temporarily widen to healthy unproven nodes instead of immediately recycling a cooling-down proven-good node.

### Transient failures versus eviction

The port-forward loop distinguishes a temporary NAT-PMP hiccup from a genuinely port-forward incapable server:

1. When a **proven-good** server (one already in `PF_CAPABLE_PROFILES_FILE`) hits `MAX_FAILURES`, the failure is treated as transient. The tunnel is kept and retried in place so the forwarded port stays stable and qBittorrent's published port -- and therefore its container -- is not recreated. Only after `PROVEN_TRANSIENT_MAX_KEEPS` consecutive transient windows without a successful port does it fall back to a full reconnect.
2. When an **unproven** server hits `MAX_FAILURES`, the port-forward loop records a consecutive incapability strike via `proton-server-manager.sh mark-incapable-attempt` and reconnects to a different server. Strikes accumulate in `/run/proton/pf-incapable-strikes.tsv` and reset the instant the server proves it can forward a port (`mark-capable`).
3. Once an unproven server accumulates `PF_INCAPABLE_STRIKE_THRESHOLD` consecutive strikes (default 3), the server manager evicts it: it is written to `PF_INCAPABLE_PROFILES_FILE` and its pool config is deleted from `WG_POOL_DIR`. A proven-good server is never evicted this way; it is only cooled down.

This keeps a working server (and its forwarded port) stable across brief Proton hiccups while still permanently removing servers that genuinely cannot forward a port.

The port-forward service must be able to write both `/etc/proton` for the learned PF-capable/incapable lists and the directory containing `QBT_PORT_ENV_FILE` for Compose port-artifact updates.

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
11. `PORT_FORWARD_REQUIRED=on`
12. `PF_CAPABLE_PROFILES_FILE=/etc/proton/pf-capable-profiles.tsv`
13. `PF_INCAPABLE_PROFILES_FILE=/etc/proton/pf-incapable-profiles.tsv`
14. `PF_INCAPABLE_STRIKES_FILE=/run/proton/pf-incapable-strikes.tsv`
15. `PF_INCAPABLE_STRIKE_THRESHOLD=3`
16. `PROVEN_TRANSIENT_MAX_KEEPS=5` (set in `proton-port-forward.env`)

Manual helpers:

1. `proton-server-manager.sh select`
2. `proton-server-manager.sh current`
3. `proton-server-manager.sh mark-bad <profile> <reason>`
4. `proton-server-manager.sh show-bad`
5. `proton-server-manager.sh reset-bad`
6. `proton-server-manager.sh mark-capable <profile> <port>`
7. `proton-server-manager.sh mark-incapable <profile> <reason>`
8. `proton-server-manager.sh mark-incapable-attempt <profile> <reason>`
9. `proton-server-manager.sh show-capable`
10. `proton-server-manager.sh show-incapable`
11. `proton-server-manager.sh show-incapable-strikes`
12. `proton-server-manager.sh reset-capable`
13. `proton-server-manager.sh reset-incapable`
14. `proton-server-manager.sh reset-incapable-strikes`

Any server rotation logic must preserve the repository routing rules, kill switch behavior, qBittorrent port synchronization, and DNS policy after reconnect.

## WireGuard Defaults

The units currently default to values such as:

1. `WG_PROFILE=proton`
2. `VPN_INTERFACE=proton`
3. `NATPMP_GATEWAY=10.2.0.1`
4. `MANAGEMENT_ALLOWED_CIDRS=<LAN_CIDR>,<YOUR_WAN_IP>/32`
5. `MANAGE_RESOLVED_DNS=auto`
6. `RESOLVED_DNS_ROUTE_DOMAIN=~.`
7. `WG_PERSISTENT_KEEPALIVE=25`

Set real values in environment files, not in committed documentation.

The up script filters each pool config into a runtime config and injects `PersistentKeepalive = <WG_PERSISTENT_KEEPALIVE>` into the `[Peer]` section when the source config omits it (an existing value is preserved, never duplicated). The keepalive stops Proton from dropping an idle tunnel's session and NAT-PMP mapping between port-forward polls, which is the main source of intermittent `natpmpc` timeouts. Set `WG_PERSISTENT_KEEPALIVE=0` to disable injection.

For the templated per-instance services, `NATPMP_GATEWAY` is not taken from this shared default. When an instance sets `WG_ADDRESS_SUBNET=<n>`, the instance loader derives `NATPMP_GATEWAY=10.<n>.0.1` (and the matching tunnel address and DNS) so each instance requests its forwarded port from its own gateway. See "Same Server and Multi Tunnel Isolation".

If your WireGuard profile or interface uses different names, update the environment files consumed by:

1. `proton-killswitch.service`
2. `proton-wg.service`
3. `proton-port-forward.service`
4. `proton-healthcheck.service`

IPv6 is intentionally not managed by the current kill switch path because it is disabled in the active Proton WireGuard profile.

### IPv6 Safe Rollout

IPv6 rollout is staged so recovery is proven before Docker networking changes. The current stage supports one tunnel-only canary while Docker remains IPv4-only.

Run the read-only checks from the repository first:

```bash
sudo ./proton-ipv6-rollout.sh status
sudo ./proton-ipv6-rollout.sh preflight
```

`preflight` must confirm all of the following before a snapshot is allowed:

1. `WG_IPV6_ENABLED` is off
2. `starr_network` has IPv6 disabled
3. The nftables kill-switch backend is selected or available through `auto`
4. The commands needed to capture and restore network state are installed

Create the rollback point before deploying any dual-stack implementation:

```bash
sudo ./proton-ipv6-rollout.sh snapshot
```

Snapshots default to `/var/lib/proton/ipv6-rollbacks/<UTC timestamp>` and include:

1. `/etc/proton`, including root-only per-instance configuration
2. `/etc/wireguard`
3. `/etc/docker`
4. `/usr/local/bin/proton`
5. Proton systemd units and the list of active units
6. Every `QBT_COMPOSE_PROJECT_DIR` discovered from the per-instance configuration
7. IPv4 and IPv6 rules and routes, the nftables ruleset, WireGuard state, and Docker network metadata for diagnosis

The snapshot contains WireGuard keys and qBittorrent credentials. It is created with root-only permissions and must not be copied into the repository or logs.

To restore immediately:

```bash
sudo /usr/local/bin/proton/proton-ipv6-rollout.sh rollback \
  /var/lib/proton/ipv6-rollbacks/latest
```

Rollback stops every currently active Proton service, restores paths that existed at snapshot time, removes managed paths that were absent at snapshot time, reloads systemd, and starts exactly the Proton services that were active in the snapshot. Services are restored sequentially by dependency class so WireGuard instances cannot race while replacing shared policy rules. A failed service is reported without preventing the remaining baseline services from being attempted.

The controller can activate one guarded tunnel canary:

```bash
sudo /usr/local/bin/proton/proton-ipv6-rollout.sh activate-canary sonarr
```

Activation verifies that the selected Proton profile has an IPv6 interface address, IPv6 DNS, and `AllowedIPs = ::/0`. It then checks the interface address, per-instance IPv6 route table, bound-interface policy rule, outbound IPv6 connectivity, and all instance services. Any failed check automatically restores the saved instance environment and restarts that instance in IPv4-only mode.

Deactivate the canary without restoring the full snapshot:

```bash
sudo /usr/local/bin/proton/proton-ipv6-rollout.sh deactivate-canary sonarr
```

Do not enable Docker IPv6 during this stage. Docker dual-stack activation still requires nftables IPv6 source enforcement, IPv6 Docker policy rules, VPN-drop tests, and Docker network recreation support to land and pass first. The IPv4 NAT-PMP and qBittorrent published-port path remains unchanged.

The kill-switch scripts understand an optional `DOCKER_NETWORK_CIDR6`. When it is empty, their live behavior remains IPv4-only. When it is set, the nftables backend installs IPv6 Docker-local rules, accepts Docker IPv6 only through active Proton interfaces, drops every other packet sourced from or destined to the Docker IPv6 subnet, and applies NAT66 only to that subnet on Proton interfaces. The iptables backend refuses to apply when `DOCKER_NETWORK_CIDR6` is set.

Do not populate `DOCKER_NETWORK_CIDR6` until all of these maintenance-window prerequisites are ready:

1. `KILLSWITCH_BACKEND=nftables` is explicit
2. Host IPv6 forwarding is enabled persistently
3. The external `starr_network` can be stopped and recreated with matching IPv6 IPAM
4. Every attached Compose project can be recreated after the network replacement
5. VPN-drop packet captures are ready to prove the ULA cannot leave through the WAN interface

The current external `starr_network` is referenced by many independent Compose projects, so its conversion is not an in-place toggle. Network recreation is intentionally excluded from tunnel-canary activation.

Before preparing a Docker maintenance window, run the read-only dual-stack gate with the proposed ULA:

```bash
sudo /usr/local/bin/proton/proton-ipv6-rollout.sh \
  docker-preflight fdca:6c19:2096::/64
```

This command requires an explicit `KILLSWITCH_BACKEND=nftables`, confirms the tested firewall scripts match their installed copies, validates a canonical ULA `/64`, rejects overlap with host routes or Docker networks, verifies `starr_network` is still IPv4-only, and requires host IPv6 forwarding to remain off. It does not write configuration, enable forwarding, apply nftables, restart services, or modify Docker.

Docker IPv6 policy routing mirrors the existing IPv4 ownership model. Each qBittorrent container receives a higher-priority IPv6 `/128` source rule for its own instance tunnel. `DOCKER_IPV6_FALLBACK_INSTANCE` names exactly one IPv6-capable tunnel that carries ordinary Docker application traffic at the lower fallback priority; it defaults to `sonarr`. Docker-to-Docker ULA traffic remains in the main table. The network watcher refreshes these rules after container recreation, and WireGuard teardown removes instance-owned IPv6 rules before flushing the tunnel table.

Deploy the complete inert firewall and routing bundle before a maintenance window:

```bash
sudo /usr/local/bin/proton_project/deploy-live-ipv6-firewall.sh deploy
```

The helper creates a root-only timestamped snapshot of all six installed scripts and prints its exact rollback path. It does not restart services or activate Docker IPv6.

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
4. `PORT_STABILITY_GRACE_SECONDS=180`

The healthcheck also pauses its low-throughput recovery ladder for a short
stabilization window after each forwarded-port update so normal NAT-PMP churn
and qBittorrent port reconfiguration do not immediately trigger another round
of recovery.

A successful one-shot NAT-PMP refresh now resets the staged ladder back to the
first step. That keeps healthy-but-slow swarms from escalating into a full
WireGuard restart just because throughput stayed below the target while the
forwarded port and qBittorrent sync path were already confirmed working.

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
ip route show table 51802
ip route show table 51803
ip route show table 51804
ip route show table 51805
ip route show table 51806
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
cat /run/proton/prowlarr/proton-port.state
cat /run/proton/prowlarr/qbt-port.cache
cat /etc/proton/instances/prowlarr/qbittorrent-port.env
```

If the active mode is `legacy-dnat`:

```bash
cat /run/proton/prowlarr/proton-port.state
cat /run/proton/prowlarr/qbt-port.cache
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' qbittorrent-prowlarr
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
sudo ip link set dev pvprowlarr down
# verify Docker hosted application traffic is blocked from leaking
# verify SSH and RDP remain reachable as intended
sudo systemctl restart proton-wg@prowlarr.service proton-port-forward@prowlarr.service proton-healthcheck@prowlarr.service
```

After recovery, recheck:

```bash
wg show
ip rule show
ip route show table 51806
```

## Optional Docker Network Watcher

If qBittorrent or other Docker hosted application services run on a bridged Docker network and routing depends on Docker network CIDR or container IP discovery, enable the per-instance watcher service to keep routing and DNAT in sync with Docker events.

The watcher listens for Docker network and container events and can:

1. Reapply Docker source-routing and raw-table return rules when the Docker network subnet changes
2. Reapply the Docker kill-switch state after Docker restarts or network changes
3. Refresh qBittorrent port state so compose-recreate or legacy-DNAT mode stays in sync

Install and start the watcher:

```bash
cd /path/to/project-bundle
sudo ./install-proton-systemd.sh
sudo systemctl daemon-reload
sudo systemctl enable --now proton-docker-watch@prowlarr.service
sudo journalctl -fu proton-docker-watch@prowlarr.service
```

Verify watcher behavior:

```bash
ip rule show | grep 51806
ip route show table 51806
sudo nft list chain ip proton_nat prerouting -a | grep qbt-dnat
```

Disable the watcher if not needed:

```bash
sudo systemctl disable --now proton-docker-watch@prowlarr.service
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
