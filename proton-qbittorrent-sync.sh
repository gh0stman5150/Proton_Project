#!/usr/bin/env bash
# Deprecated: systemd units use proton-qbittorrent-sync-safe.sh.
set -euo pipefail

ENV_FILE="/usr/local/bin/proton/proton-qbittorrent.env"
STATE_FILE="/usr/local/bin/proton/proton-port.state"
CACHE_FILE="/run/proton-qbt-port.cache"
LOG_TAG="proton-qbt"

log() {
	echo "$(date '+%F %T') | $*" | systemd-cat -t "$LOG_TAG"
}

# Load env
if [[ -f "$ENV_FILE" ]]; then
	# shellcheck disable=SC1090
	source "$ENV_FILE"
else
	log "ERROR: Env file not found: $ENV_FILE"
	exit 1
fi

# Validate required vars
: "${QBITTORRENT_URL:?Missing QBITTORRENT_URL}"
: "${QBITTORRENT_USER:?Missing QBITTORRENT_USER}"
: "${QBITTORRENT_PASS:?Missing QBITTORRENT_PASS}"

# Get current forwarded port
PORT=$(cat "$STATE_FILE" 2>/dev/null || true)

if [[ -z "$PORT" ]]; then
	log "No port found, skipping"
	exit 0
fi

# Avoid redundant updates
if [[ -f "$CACHE_FILE" ]]; then
	LAST_PORT=$(cat "$CACHE_FILE")
	if [[ "$PORT" == "$LAST_PORT" ]]; then
		log "Port unchanged ($PORT), skipping update"
		exit 0
	fi
fi

log "Updating qBittorrent port → $PORT"

# Authenticate
COOKIE=$(curl -s -i \
	--data "username=$QBITTORRENT_USER&password=$QBITTORRENT_PASS" \
	"$QBITTORRENT_URL/api/v2/auth/login" |
	grep -Fi set-cookie | cut -d' ' -f2)

if [[ -z "$COOKIE" ]]; then
	log "ERROR: Authentication failed"
	exit 1
fi

# Apply port
curl -s --cookie "$COOKIE" \
	--data "json={\"listen_port\":$PORT}" \
	"$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null

# Cache port
echo "$PORT" >"$CACHE_FILE"

log "qBittorrent updated successfully"
