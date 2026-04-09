#!/bin/bash

set -euo pipefail

BACKUP_DIR="/tmp/protonvpn-hardening-backup"
CONNECT_BACKUP="$BACKUP_DIR/protonvpn-connect.sh.bak"
PORT_FORWARD_BACKUP="$BACKUP_DIR/protonvpn-port-forward.sh.bak"
HEALTHCHECK_BACKUP="$BACKUP_DIR/protonvpn-port-forward-healthcheck.sh.bak"
CONNECT_SERVICE_BACKUP="$BACKUP_DIR/protonvpn-connect.service.bak"
PORT_FORWARD_SERVICE_BACKUP="$BACKUP_DIR/protonvpn-port-forward.service.bak"
ENV_BACKUP="$BACKUP_DIR/protonvpn-port-forward.env.bak"

require_file() {
	local path="$1"

	if [[ ! -f "$path" ]]; then
		echo "ERROR: Required backup file not found: $path" >&2
		exit 1
	fi
}

for file in \
	"$CONNECT_BACKUP" \
	"$PORT_FORWARD_BACKUP" \
	"$CONNECT_SERVICE_BACKUP" \
	"$PORT_FORWARD_SERVICE_BACKUP"; do
	require_file "$file"
done

sudo install -m 0755 "$CONNECT_BACKUP" /usr/local/bin/protonvpn-connect.sh
sudo install -m 0755 "$PORT_FORWARD_BACKUP" /usr/local/bin/protonvpn-port-forward.sh
if [[ -f "$HEALTHCHECK_BACKUP" ]]; then
	sudo install -m 0755 "$HEALTHCHECK_BACKUP" /usr/local/bin/protonvpn-port-forward-healthcheck.sh
else
	sudo rm -f /usr/local/bin/protonvpn-port-forward-healthcheck.sh
fi
sudo install -m 0644 "$CONNECT_SERVICE_BACKUP" /etc/systemd/system/protonvpn-connect.service
sudo install -m 0644 "$PORT_FORWARD_SERVICE_BACKUP" /etc/systemd/system/protonvpn-port-forward.service

if [[ -f "$ENV_BACKUP" ]]; then
	sudo install -m 0600 "$ENV_BACKUP" /etc/default/protonvpn-port-forward
else
	sudo rm -f /etc/default/protonvpn-port-forward
fi

sudo systemctl daemon-reload
sudo systemctl restart protonvpn-connect.service

echo "ProtonVPN files restored from $BACKUP_DIR"
