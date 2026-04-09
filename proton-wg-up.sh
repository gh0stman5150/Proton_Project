#!/usr/bin/env bash
# Deprecated: systemd units use proton-wg-up-safe.sh.
set -euo pipefail

LOG_TAG="proton-wg"

log() {
	echo "$(date '+%F %T') | $*" | systemd-cat -t "$LOG_TAG"
}

log "Bringing up WireGuard..."

wg-quick down proton 2>/dev/null || true
wg-quick up proton

sleep 5

IP=$(ip -4 addr show wg0 | awk '/inet / {print $2}' | cut -d/ -f1)

log "WireGuard up with IP: $IP"
