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

for cmd in awk cat chmod curl cut grep mkdir stat systemd-cat tr docker nft; do
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

# --- DNAT: map public port -> qB container internal port (starr network) ---
QBT_CONTAINER_NAME="${QBT_CONTAINER_NAME:-qbittorrent}"
QBT_INTERNAL_PORT="${QBT_INTERNAL_PORT:-6881}"
NFT_TABLE="proton_nat"
NFT_CHAIN="prerouting"

ensure_nft_nat() {
    nft list table ip "$NFT_TABLE" >/dev/null 2>&1 || nft add table ip "$NFT_TABLE"
    nft list chain ip "$NFT_TABLE" "$NFT_CHAIN" >/dev/null 2>&1 || \
        nft add chain ip "$NFT_TABLE" "$NFT_CHAIN" '{ type nat hook prerouting priority 0 ; }'
}

container_ip_for() {
    local name="$1"
    local network="${QBT_NETWORK_NAME:-}"

    if [[ -n "$network" ]]; then
        # network-specific IP
        docker inspect -f "{{.NetworkSettings.Networks.$network.IPAddress}}" "$name" 2>/dev/null || true
        return
    fi

    # fallback: first network IP
    docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name" 2>/dev/null || true
}

remove_existing_qbt_dnat() {
    # remove any existing rules we added with comment "qbt-dnat"
    if ! nft list chain ip "$NFT_TABLE" "$NFT_CHAIN" -a >/dev/null 2>&1; then
        return 0
    fi

    # find handles for rules with comment qbt-dnat
    local handles
    handles=$(nft list chain ip "$NFT_TABLE" "$NFT_CHAIN" -a 2>/dev/null | awk '/qbt-dnat/ {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')
    if [[ -z "$handles" ]]; then
        return 0
    fi

    for h in $handles; do
        nft delete rule ip "$NFT_TABLE" "$NFT_CHAIN" handle "$h" 2>/dev/null || true
    done
}

add_qbt_dnat() {
    local pub_port="$1"
    local cip
    cip=$(container_ip_for "$QBT_CONTAINER_NAME" )
    if [[ -z "$cip" ]]; then
        log "WARNING: qBittorrent container '$QBT_CONTAINER_NAME' IP not found; skipping DNAT"
        return 0
    fi

    ensure_nft_nat
    # Remove previous DNAT rules added by this script
    remove_existing_qbt_dnat

    # Add new rule with a comment so we can identify it later
    nft add rule ip "$NFT_TABLE" "$NFT_CHAIN" tcp dport "$pub_port" dnat to "$cip":"$QBT_INTERNAL_PORT" comment "qbt-dnat" || \
        log "ERROR: Failed to add DNAT rule for qBittorrent"

    log "Installed DNAT: public $pub_port -> $cip:$QBT_INTERNAL_PORT"
}

# Update DNAT unless container mode is host or no container specified
if [[ -n "$PORT" ]]; then
    add_qbt_dnat "$PORT"
fi
