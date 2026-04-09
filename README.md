# Proton WireGuard Helper Scripts

This project manages a Proton WireGuard tunnel, a host-side kill switch, NAT-PMP port forwarding, qBittorrent port synchronization, server-pool rotation, and throughput health checks.

## Active Service Path

The systemd units are wired to the hardened entrypoints:

- `proton-killswitch-dispatch.sh`
- `proton-killswitch-safe.sh`
- `proton-killswitch-nft.sh`
- `proton-wg-up-safe.sh`
- `proton-wg-down-safe.sh`
- `proton-port-forward-safe.sh`
- `proton-qbittorrent-sync-safe.sh`
- `proton-server-manager.sh`
- `proton-healthcheck.sh`
- `install-proton-systemd.sh`

The older scripts remain in the repo for reference only.

The kill-switch dispatcher defaults to `KILLSWITCH_BACKEND=auto`, which prefers `nftables` when `nft` is installed and falls back to the iptables backend otherwise.

The iptables backend intentionally manages dedicated `INPUT` and `OUTPUT` chains only. It leaves Docker-managed `FORWARD` and `nat` chains alone so container networking is not wiped during startup.

The active systemd units also use `Restart=on-failure`, start-rate limits, `UMask=0077`, and conservative service sandboxing so transient failures do not spin forever and the long-running helpers keep a smaller filesystem and address-family footprint.

## Required qBittorrent Env File

The installer copies [proton-qbittorrent.env](/usr/local/bin/proton/proton-qbittorrent.env) to `/etc/proton/qbittorrent.env` and keeps it root-owned with mode `600`.

The template is:

```bash
QBITTORRENT_URL=http://127.0.0.1:8081
QBITTORRENT_USER=change-me
QBITTORRENT_PASS=change-me
```

Additional optional vars (installed by the installer template) when qBittorrent runs on a Docker "starr"/bridge network:

```bash
# Container name (docker): default qbittorrent
QBT_CONTAINER_NAME=qbittorrent
# Internal torrent listen port inside the container (default 6881)
QBT_INTERNAL_PORT=6881
# Optional Docker network name to lookup container IP (default: first network IP)
QBT_NETWORK_NAME=starr
```

If these are present the host-side sync script will add an nft DNAT rule that maps the Proton public forwarded port -> the qBittorrent container internal port. This preserves the container on the `starr` network (no recreate) while keeping inbound forwarding functional.

Because the Proton services run on the host, `QBITTORRENT_URL` should point at the host-published qBittorrent Web UI port. Docker network names such as `starr_network` are not directly reachable from these host systemd services unless you separately proxy or publish them.

The hardened path expects:

- File path: `/etc/proton/qbittorrent.env`
- Owner: `root`
- Mode: `600`

## Install

Run [install-proton-systemd.sh](/usr/local/bin/proton/install-proton-systemd.sh) as root on the Linux host. It:

- Copies the active Proton scripts to `/usr/local/bin/proton`
- Copies the systemd unit files to `/etc/systemd/system`
- Copies env templates to `/etc/proton`
- Secures the active WireGuard config as `root:root` with mode `600`
- Preserves an existing `/etc/proton/qbittorrent.env` and writes updates to `*.new` files instead of overwriting secrets
- Runs `systemctl daemon-reload`
- Enables and restarts the Proton services

Run it from the project bundle directory that contains the scripts, `*.service`, and `*.env` files together. Re-running it from `/usr/local/bin/proton` only works if that directory also contains the full bundle, not just the installed helper scripts.

You can also pass qBittorrent credentials directly during install:

```bash
sudo ./install-proton-systemd.sh \
  --qb-url http://127.0.0.1:8081 \
  --qb-user your-user \
  --qb-pass your-pass
```

You may also set Docker-related values at install time:

```bash
sudo ./install-proton-systemd.sh \
  --qb-container qbittorrent \
  --qb-int-port 6881 \
  --qb-network starr
```

## Runtime State

Live port-forward state is stored under `/run/proton`:

- `/run/proton/proton-port.state`
- `/run/proton/qbt-port.cache`
- `/run/proton/current-server.env`
- `/run/proton/bad-servers.tsv`
- `/run/proton/reselect-server.flag`
- `/run/proton/recovery.lock`

Do not keep live state files in the repository.

## Server Pool And Latency Selection

If `/etc/wireguard/proton-pool` contains one or more `*.conf` files, the active path automatically treats that directory as a rotation pool. Each reconnect or bad-node recovery can select the lowest-latency candidate by probing the endpoint IP from each config.

The selector stores the active choice in `/run/proton/current-server.env` and tracks cooldowns in `/run/proton/bad-servers.tsv`. It also applies hysteresis so the current server is kept unless a replacement is meaningfully better or the current server is degraded.

By default the selector also lints each candidate before it can be selected. It rejects configs that contain `PreUp`, `PostUp`, `PreDown`, `PostDown`, or `SaveConfig`, and it expects `DNS` to match `WG_EXPECTED_DNS` unless `WG_LINT_ALLOW_MISSING_DNS=on`.

Useful knobs:

- `WG_POOL_DIR=/etc/wireguard/proton-pool`
- `SERVER_POOL_ENABLED=auto`
- `BAD_SERVER_COOLDOWN=900`
- `SERVER_SWITCH_MIN_IMPROVEMENT_MS=10`
- `SERVER_SWITCH_DEGRADED_LATENCY_MS=75`
- `PING_TIMEOUT_SECONDS=1`
- `PING_COUNT=1`
- `SERVER_POOL_STRICT_LINT=on`
- `WG_EXPECTED_DNS=10.2.0.1`
- `WG_LINT_ALLOW_MISSING_DNS=off`

Manual helpers:

- `proton-server-manager.sh select`
- `proton-server-manager.sh current`
- `proton-server-manager.sh mark-bad <profile> <reason>`
- `proton-server-manager.sh show-bad`
- `proton-server-manager.sh reset-bad`

## WireGuard Defaults

The units default to:

- `WG_PROFILE=proton`
- `VPN_INTERFACE=proton`
- `NATPMP_GATEWAY=10.2.0.1`
- `MANAGEMENT_ALLOWED_CIDRS=192.168.237.0/24,24.225.97.122/32`
- `MANAGE_RESOLVED_DNS=auto`
- `RESOLVED_DNS_ROUTE_DOMAIN=~.`

If your WireGuard profile or interface uses different names, update the env files consumed by:

- [proton-killswitch.service](/usr/local/bin/proton/proton-killswitch.service)
- [proton-wg.service](/usr/local/bin/proton/proton-wg.service)
- [proton-port-forward.service](/usr/local/bin/proton/proton-port-forward.service)
- [proton-healthcheck.service](/usr/local/bin/proton/proton-healthcheck.service)

IPv6 is intentionally not managed by the kill-switch script because it is disabled in the Proton/WireGuard profile.

When `MANAGE_RESOLVED_DNS=auto` and `resolvectl` is available, the WireGuard up/down scripts explicitly program and revert interface DNS using the selected profile DNS values. That helps keep host DNS pinned to the tunnel on `systemd-resolved` systems.

If qBittorrent runs in a bridged Docker network and you also want container egress constrained by the VPN, handle that at the container/network-namespace level. The host kill switch is now careful not to overwrite Docker's own firewall chains.

## Healthcheck

`proton-healthcheck.service` watches qBittorrent only when there are active transfers. If combined download and upload throughput stays below the configured threshold for multiple checks, it now uses a staged recovery ladder: qBittorrent port/DNAT refresh, then a one-shot NAT-PMP refresh, and only then a bad-server mark plus Proton service restart. The healthcheck and port-forward loop share `RECOVERY_LOCK_FILE` so they do not trigger overlapping reconnect storms.

Default thresholds:

- `CHECK_INTERVAL=60`
- `MIN_COMBINED_SPEED_BPS=65536`
- `MAX_LOW_SPEED_CHECKS=3`

Tune those values in [proton-healthcheck.service](/usr/local/bin/proton/proton-healthcheck.service) if your workload is bursty or often idle between peer activity.

## Quick verification

After install/restart, verify the key pieces are present:

- WireGuard + routes:

```bash
wg show
ip rule show
ip route show table 51820
```

- nft kill-switch and DNAT (if enabled):

```bash
sudo nft list table inet proton
sudo nft list table ip proton_nat     # shows DNAT rule with comment qbt-dnat
```

- qBittorrent mapping and state:

```bash
cat /run/proton/proton-port.state
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $QBT_CONTAINER_NAME
sudo nft list chain ip proton_nat prerouting -a | grep qbt-dnat
```

Simulate VPN down/up in a safe environment to confirm the kill-switch blocks leaks (and SSH/RDP still reachable):

```bash
sudo ip link set dev $VPN_INTERFACE down
# test outbound connectivity (should be blocked for app traffic)
# bring back up
sudo ip link set dev $VPN_INTERFACE up
```

## Optional: Docker network watcher

If you run qBittorrent on a bridged Docker network and also want the host-side routing and DNAT to stay in sync with Docker network/container changes, enable the optional watcher service. It listens for Docker network/container events and will:

- Re-apply the `ip rule from <DOCKER_NETWORK_CIDR>` -> VPN table rule when the Docker network subnet changes.
- Refresh the qBittorrent DNAT mapping (public port -> container IP:internal_port) by invoking the existing sync script.

Install and start the watcher using the installer (it is included in the bundle) or manually:

```bash
# (installer) re-run the installer to copy new files and reload units
sudo ./install-proton-systemd.sh

sudo systemctl daemon-reload
sudo systemctl enable --now proton-docker-watch.service
sudo journalctl -fu proton-docker-watch.service
```

Verify the watcher has applied routing and DNAT as expected:

```bash
ip rule show | grep 51820
ip route show table 51820
sudo nft list chain ip proton_nat prerouting -a | grep qbt-dnat
```

To disable the watcher:

```bash
sudo systemctl disable --now proton-docker-watch.service
```

