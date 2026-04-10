#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${QBITTORRENT_ENV_FILE:-/etc/proton/qbittorrent.env}"
STATE_FILE="${STATE_FILE:-/run/proton/proton-port.state}"
CACHE_FILE="${CACHE_FILE:-/run/proton/qbt-port.cache}"
LOG_TAG="${LOG_TAG:-proton-qbt}"
CACHE_DIR="${CACHE_FILE%/*}"
NFT_TABLE="${NFT_TABLE:-proton_nat}"
NFT_CHAIN="${NFT_CHAIN:-prerouting}"
NFT_COMMENT="${NFT_COMMENT:-qbt-dnat}"

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
QBT_INTERNAL_PORT="${QBT_INTERNAL_PORT:-6881}"
QBT_NETWORK_NAME="${QBT_NETWORK_NAME:-}"
QBT_CONTAINER_NAME="${QBT_CONTAINER_NAME:-}"

PORT="$(awk -F= '/^CURRENT_PORT=/ {print $2; exit}' "$STATE_FILE" 2>/dev/null || true)"

if [[ -z "$PORT" ]]; then
    log "No port found, skipping"
    exit 0
fi


container_ip() {
    if [[ -z "$QBT_CONTAINER_NAME" ]] || ! command -v docker >/dev/null 2>&1; then
        return 0
    fi

    if [[ -n "$QBT_NETWORK_NAME" ]]; then
        docker inspect -f "{{with index .NetworkSettings.Networks \"${QBT_NETWORK_NAME}\"}}{{.IPAddress}}{{end}}" "$QBT_CONTAINER_NAME" 2>/dev/null || true
        return 0
    fi

    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{break}}{{end}}' "$QBT_CONTAINER_NAME" 2>/dev/null || true
}

ensure_dnat_mapping() {
    local ip="$1"
    local handles

    [[ -n "$ip" ]] || return 0

    if ! command -v nft >/dev/null 2>&1; then
        log "nft not available; skipping DNAT refresh"
        return 0
    fi

    nft list table ip "$NFT_TABLE" >/dev/null 2>&1 || nft add table ip "$NFT_TABLE"
    nft list chain ip "$NFT_TABLE" "$NFT_CHAIN" >/dev/null 2>&1 || \
        nft 'add chain ip '"$NFT_TABLE"' '"$NFT_CHAIN"' { type nat hook prerouting priority dstnat; policy accept; }'

    handles="$(nft list chain ip "$NFT_TABLE" "$NFT_CHAIN" -a 2>/dev/null | awk -v comment="$NFT_COMMENT" '$0 ~ comment {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')"
    if [[ -n "$handles" ]]; then
        while read -r handle; do
            [[ -n "$handle" ]] || continue
            nft delete rule ip "$NFT_TABLE" "$NFT_CHAIN" handle "$handle" 2>/dev/null || true
        done <<< "$handles"
    fi

    nft add rule ip "$NFT_TABLE" "$NFT_CHAIN" tcp dport "$PORT" dnat to "${ip}:${QBT_INTERNAL_PORT}" comment "$NFT_COMMENT"
    log "DNAT refreshed: tcp dport ${PORT} -> ${ip}:${QBT_INTERNAL_PORT}"
}

if [[ -f "$CACHE_FILE" ]]; then
    LAST_PORT="$(cat "$CACHE_FILE")"
    if [[ "$PORT" == "$LAST_PORT" ]]; then
        if [[ -n "$QBT_CONTAINER_NAME" ]]; then
            IP="$(container_ip)"
            ensure_dnat_mapping "$IP"
        fi
        log "Port unchanged ($PORT), skipping update"
        exit 0
    fi
fi

log "Updating qBittorrent port -> $PORT"

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

LOGIN_BODY="$(curl -fsS \
    -c "$COOKIE_JAR" \
    --data "username=$QBITTORRENT_USER&password=$QBITTORRENT_PASS" \
    "$QBITTORRENT_URL/api/v2/auth/login" || true)"

if [[ "$LOGIN_BODY" != "Ok." ]]; then
    log "ERROR: Authentication failed"
    exit 1
fi

curl -fsS -b "$COOKIE_JAR" -X POST \
    --data 'json={"random_port":false}' \
    "$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null

curl -fsS -b "$COOKIE_JAR" -X POST \
    --data "json={\"listen_port\":$PORT}" \
    "$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null

APPLIED_PORT="$(
    curl -fsS -b "$COOKIE_JAR" \
    "$QBITTORRENT_URL/api/v2/app/preferences" \
    | tr ',{}' '\n' \
    | awk -F: '/"listen_port"/ {gsub(/[^0-9]/, "", $2); print $2; exit}'
)"

if [[ "$APPLIED_PORT" != "$PORT" ]]; then
    log "ERROR: qBittorrent did not apply port $PORT (reported: ${APPLIED_PORT:-unknown})"
    exit 1
fi

umask 077
echo "$PORT" > "$CACHE_FILE"

log "qBittorrent updated successfully"
