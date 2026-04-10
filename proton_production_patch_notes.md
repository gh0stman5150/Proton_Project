# Proton production patch set

This patch bundle folds together the earlier consistency fixes and the runtime internet-connectivity fix.

## Included fixes

- Preserve NAT-PMP loop uptime on failures in `proton-port-forward-safe.sh`
- Install missing runtime files from the installer:
  - `proton-qbt-dnat-cleanup.sh`
  - `proton-docker-network-watcher.sh`
  - `proton-docker-watch.service`
- Preserve Docker/qBittorrent env fields during installs and support installer flags for them
- Restore qBittorrent DNAT refresh behavior in `proton-qbittorrent-sync-safe.sh`
- Add postrouting masquerade/SNAT for VPN egress in both kill-switch backends:
  - `proton-killswitch-nft.sh`
  - `proton-killswitch-safe.sh`
- Clean up VPN NAT state in `proton-killswitch-reset.sh`
- Remove `bash -x` from `proton-wg.service`
- Sanitize committed qBittorrent credentials in `proton-qbittorrent.env`

## Validation performed

- `bash -n` passed for all modified shell scripts and units referenced by this patch set.

## Apply

From the repo root:

```bash
patch -p0 < proton_production_patch.patch
```

If your local tree is a Git checkout and you prefer Git:

```bash
git apply proton_production_patch.patch
```

## Important after applying

Rotate the qBittorrent password if the committed credential was ever real.

Then reinstall/redeploy:

```bash
sudo ./install-proton-systemd.sh
sudo systemctl restart proton-killswitch.service proton-wg.service proton-port-forward.service proton-healthcheck.service
```

## Quick verification

```bash
sudo nft list table inet proton
sudo nft list table ip proton_nat
ip route get 1.1.1.1 mark 0xca6c
ping -c 2 1.1.1.1
ping -c 2 google.com
```
