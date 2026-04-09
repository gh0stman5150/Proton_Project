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

## Required qBittorrent Env File

The installer copies [proton-qbittorrent.env](/usr/local/bin/proton/proton-qbittorrent.env) to `/etc/proton/qbittorrent.env` and keeps it root-owned with mode `600`.

The template is:

```bash
QBITTORRENT_URL=http://127.0.0.1:8081
QBITTORRENT_USER=change-me
QBITTORRENT_PASS=change-me
```

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

## Runtime State

Live port-forward state is stored under `/run/proton`:

- `/run/proton/proton-port.state`
- `/run/proton/qbt-port.cache`
- `/run/proton/current-server.env`
- `/run/proton/bad-servers.tsv`
- `/run/proton/reselect-server.flag`

Do not keep live state files in the repository.

## Server Pool And Latency Selection

If `/etc/wireguard/proton-pool` contains one or more `*.conf` files, the active path automatically treats that directory as a rotation pool. Each reconnect or bad-node recovery can select the lowest-latency candidate by probing the endpoint IP from each config.

The selector stores the active choice in `/run/proton/current-server.env` and tracks cooldowns in `/run/proton/bad-servers.tsv`.

Useful knobs:

- `WG_POOL_DIR=/etc/wireguard/proton-pool`
- `SERVER_POOL_ENABLED=auto`
- `BAD_SERVER_COOLDOWN=900`
- `PING_TIMEOUT_SECONDS=1`
- `PING_COUNT=1`

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

If your WireGuard profile or interface uses different names, update the env files consumed by:

- [proton-killswitch.service](/usr/local/bin/proton/proton-killswitch.service)
- [proton-wg.service](/usr/local/bin/proton/proton-wg.service)
- [proton-port-forward.service](/usr/local/bin/proton/proton-port-forward.service)
- [proton-healthcheck.service](/usr/local/bin/proton/proton-healthcheck.service)

IPv6 is intentionally not managed by the kill-switch script because it is disabled in the Proton/WireGuard profile.

If qBittorrent runs in a bridged Docker network and you also want container egress constrained by the VPN, handle that at the container/network-namespace level. The host kill switch is now careful not to overwrite Docker's own firewall chains.

## Healthcheck

`proton-healthcheck.service` watches qBittorrent only when there are active transfers. If combined download and upload throughput stays below the configured threshold for multiple checks, it marks the current server bad and restarts the Proton services.

Default thresholds:

- `CHECK_INTERVAL=60`
- `MIN_COMBINED_SPEED_BPS=65536`
- `MAX_LOW_SPEED_CHECKS=3`

Tune those values in [proton-healthcheck.service](/usr/local/bin/proton/proton-healthcheck.service) if your workload is bursty or often idle between peer activity.
