#!/usr/bin/env bash
set -euo pipefail

# Back up existing runtime WireGuard configs, remove them so wg-quick will
# regenerate per-instance runtime files, restart each proton-wg@ instance,
# and print selection/runtime/port state for verification.

BACKUP_ROOT="/run/proton/runtime-backup-$(date +%s)"
mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"

cp -a /etc/wireguard/proton-runtime/*.conf "$BACKUP_ROOT" 2>/dev/null || true
rm -f /etc/wireguard/proton-runtime/*.conf || true

instances=(lidarr radarr sonarr whisparr prowlarr)

for inst in "${instances[@]}"; do
	echo "=== restart $inst ==="
	systemctl restart "proton-wg@${inst}" || true
	sleep 2
	echo "--- /run/proton/$inst/current-server.env ---"
	sed -n '1,120p' /run/proton/$inst/current-server.env 2>/dev/null || true
	sel="$(awk -F= '/^SELECTED_WG_PROFILE=/ {print $2; exit}' /run/proton/$inst/current-server.env 2>/dev/null || true)"
	if [[ -n "$sel" ]]; then
		echo "--- /etc/wireguard/proton-runtime/${sel}.conf ---"
		sed -n '1,160p' "/etc/wireguard/proton-runtime/${sel}.conf" 2>/dev/null || true
	fi
	echo "--- /run/proton/$inst/proton-port.state ---"
	sed -n '1,80p' /run/proton/$inst/proton-port.state 2>/dev/null || true
	echo
done

echo "Runtime backup saved to $BACKUP_ROOT"

exit 0
