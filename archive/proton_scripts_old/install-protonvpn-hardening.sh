#!/bin/bash

set -euo pipefail

CONNECT_SRC="/tmp/protonvpn-connect.sh"
PORT_FORWARD_SRC="/tmp/protonvpn-port-forward.sh"
HEALTHCHECK_SRC="/tmp/protonvpn-port-forward-healthcheck.sh"
CONNECT_SERVICE_SRC="/tmp/protonvpn-connect.service"
PORT_FORWARD_SERVICE_SRC="/tmp/protonvpn-port-forward.service"
ENV_SRC="/tmp/protonvpn-port-forward.env"
BACKUP_DIR="/tmp/protonvpn-hardening-backup"

require_file() {
	local path="$1"

	if [[ ! -f "$path" ]]; then
		echo "ERROR: Required file not found: $path" >&2
		exit 1
	fi
}

for file in \
	"$CONNECT_SRC" \
	"$PORT_FORWARD_SRC" \
	"$HEALTHCHECK_SRC" \
	"$CONNECT_SERVICE_SRC" \
	"$PORT_FORWARD_SERVICE_SRC" \
	"$ENV_SRC"; do
	require_file "$file"
done

mkdir -p "$BACKUP_DIR"

sudo install -m 0755 /usr/local/bin/protonvpn-connect.sh "$BACKUP_DIR/protonvpn-connect.sh.bak"
sudo install -m 0755 /usr/local/bin/protonvpn-port-forward.sh "$BACKUP_DIR/protonvpn-port-forward.sh.bak"
if [[ -f /usr/local/bin/protonvpn-port-forward-healthcheck.sh ]]; then
	sudo install -m 0755 /usr/local/bin/protonvpn-port-forward-healthcheck.sh "$BACKUP_DIR/protonvpn-port-forward-healthcheck.sh.bak"
fi
sudo install -m 0644 /etc/systemd/system/protonvpn-connect.service "$BACKUP_DIR/protonvpn-connect.service.bak"
sudo install -m 0644 /etc/systemd/system/protonvpn-port-forward.service "$BACKUP_DIR/protonvpn-port-forward.service.bak"

if [[ -f /etc/default/protonvpn-port-forward ]]; then
	sudo install -m 0600 /etc/default/protonvpn-port-forward "$BACKUP_DIR/protonvpn-port-forward.env.bak"
fi

sudo install -m 0755 "$CONNECT_SRC" /usr/local/bin/protonvpn-connect.sh
sudo install -m 0755 "$PORT_FORWARD_SRC" /usr/local/bin/protonvpn-port-forward.sh
sudo install -m 0755 "$HEALTHCHECK_SRC" /usr/local/bin/protonvpn-port-forward-healthcheck.sh
sudo install -m 0644 "$CONNECT_SERVICE_SRC" /etc/systemd/system/protonvpn-connect.service
sudo install -m 0644 "$PORT_FORWARD_SERVICE_SRC" /etc/systemd/system/protonvpn-port-forward.service
sudo install -m 0600 "$ENV_SRC" /etc/default/protonvpn-port-forward

sudo systemctl daemon-reload
sudo systemctl restart protonvpn-connect.service

echo "ProtonVPN hardening files installed and protonvpn-connect.service restarted."
echo "Rollback backups saved in $BACKUP_DIR"
