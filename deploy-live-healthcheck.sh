#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="/usr/local/bin/proton_project"
LIVE_DIR="/usr/local/bin/proton"

install -m 755 "$PROJECT_DIR/proton-healthcheck.sh" "$LIVE_DIR/proton-healthcheck.sh"

echo "Deployed proton-healthcheck.sh to $LIVE_DIR"

INSTANCES=(lidarr radarr sonarr whisparr prowlarr)
for instance in "${INSTANCES[@]}"; do
	svc="proton-healthcheck@${instance}.service"
	if systemctl is-active --quiet "$svc" 2>/dev/null; then
		systemctl restart "$svc"
		echo "Restarted $svc"
	fi
done
