#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${QBITTORRENT_ENV_FILE:-/etc/proton/qbittorrent.env}"
STATE_FILE="${STATE_FILE:-/run/proton/proton-port.state}"
CACHE_FILE="${CACHE_FILE:-/run/proton/qbt-port.cache}"
LOG_TAG="${LOG_TAG:-proton-qbt}"
CACHE_DIR="${CACHE_FILE%/*}"

if [[ "$CACHE_DIR" == "$CACHE_FILE" ]]; then
    CACHE_DIR="."
fi

log() {
    echo "$(date '+%F %T') | $*" | systemd-cat -t "$LOG_TAG"
}

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: Required command '$cmd' is not installed."
        exit 1
    fi
}

for cmd in awk cat chmod curl cut grep mkdir stat systemd-cat tr; do
    require_command "$cmd"
done

mkdir -p "$CACHE_DIR"
chmod 700 "$CACHE_DIR"

if [[ -f "$ENV_FILE" ]]; then
    ENV_MODE="$(stat -c '%a' "$ENV_FILE")"
    ENV_OWNER="$(stat -c '%u' "$ENV_FILE")"

    if [[ "$ENV_MODE" != "600" ]]; then
        log "ERROR: $ENV_FILE must have mode 600"
        exit 1
    fi

    if [[ "$ENV_OWNER" != "0" ]]; then
        log "ERROR: $ENV_FILE must be owned by root"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$ENV_FILE"
else
    log "ERROR: Env file not found: $ENV_FILE"
    exit 1
fi

: "${QBITTORRENT_URL:?Missing QBITTORRENT_URL}"
: "${QBITTORRENT_USER:?Missing QBITTORRENT_USER}"
: "${QBITTORRENT_PASS:?Missing QBITTORRENT_PASS}"

QBITTORRENT_URL="${QBITTORRENT_URL%/}"

PORT="$(awk -F= '/^CURRENT_PORT=/ {print $2; exit}' "$STATE_FILE" 2>/dev/null || true)"

if [[ -z "$PORT" ]]; then
    log "No port found, skipping"
    exit 0
fi

if [[ -f "$CACHE_FILE" ]]; then
    LAST_PORT="$(cat "$CACHE_FILE")"
    if [[ "$PORT" == "$LAST_PORT" ]]; then
        log "Port unchanged ($PORT), skipping update"
        exit 0
    fi
fi

log "Updating qBittorrent port -> $PORT"

AUTH_RESPONSE="$(curl -fsS -i \
    --data "username=$QBITTORRENT_USER&password=$QBITTORRENT_PASS" \
    "$QBITTORRENT_URL/api/v2/auth/login" || true)"
COOKIE="$(printf '%s' "$AUTH_RESPONSE" | grep -Fi set-cookie | cut -d' ' -f2 | tr -d '\r')"

if [[ -z "$COOKIE" ]]; then
    log "ERROR: Authentication failed"
    exit 1
fi

curl -fsS --cookie "$COOKIE" \
    -X POST \
    --data "json={\"listen_port\":$PORT}" \
    "$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null

umask 077
echo "$PORT" > "$CACHE_FILE"

log "qBittorrent updated successfully"
