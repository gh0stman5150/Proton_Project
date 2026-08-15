#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="/usr/local/bin/proton_project"
LIVE_DIR="/usr/local/bin/proton"

install -m 755 "$PROJECT_DIR/proton-wg-up-safe.sh" "$LIVE_DIR/proton-wg-up-safe.sh"
install -m 755 "$PROJECT_DIR/proton-wg-down-safe.sh" "$LIVE_DIR/proton-wg-down-safe.sh"

echo "Deployed proton-wg-up-safe.sh and proton-wg-down-safe.sh to $LIVE_DIR"

INSTANCES=(lidarr radarr sonarr whisparr prowlarr)
for instance in "${INSTANCES[@]}"; do
	for svc in "proton-port-forward@${instance}.service" "proton-healthcheck@${instance}.service"; do
		if systemctl is-active --quiet "$svc" 2>/dev/null; then
			systemctl restart "$svc"
			echo "Restarted $svc"
		fi
	done
done
