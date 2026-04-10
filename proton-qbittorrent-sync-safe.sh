#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${QBITTORRENT_ENV_FILE:-/etc/proton/qbittorrent.env}"
STATE_FILE="${STATE_FILE:-/run/proton/proton-port.state}"
CACHE_FILE="${CACHE_FILE:-/run/proton/qbt-port.cache}"
DNAT_CLEANUP_SCRIPT="${DNAT_CLEANUP_SCRIPT:-${SCRIPT_DIR}/proton-qbt-dnat-cleanup.sh}"
LOG_TAG="${LOG_TAG:-proton-qbt}"
CACHE_DIR="${CACHE_FILE%/*}"
QBT_INTERNAL_PORT="${QBT_INTERNAL_PORT:-6881}"

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

for cmd in awk chmod curl grep mkdir mktemp rm sleep stat systemd-cat tr; do
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

if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
    log "ERROR: Invalid port value: $PORT"
    exit 1
fi

if [[ ! "$QBT_INTERNAL_PORT" =~ ^[0-9]+$ ]]; then
    log "ERROR: Invalid QBT_INTERNAL_PORT value: $QBT_INTERNAL_PORT"
    exit 1
fi

COOKIE_JAR="$(mktemp)"
cleanup() {
    rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

login_qbt() {
    local login_body

    : > "$COOKIE_JAR"
    login_body="$(curl -fsS \
        -c "$COOKIE_JAR" \
        --data-urlencode "username=$QBITTORRENT_USER" \
        --data-urlencode "password=$QBITTORRENT_PASS" \
        "$QBITTORRENT_URL/api/v2/auth/login" || true)"

    if [[ "$login_body" != "Ok." ]]; then
        log "ERROR: Authentication failed"
        return 1
    fi
}

get_qbt_listen_port() {
    curl -fsS -b "$COOKIE_JAR" \
        "$QBITTORRENT_URL/api/v2/app/preferences" \
        | tr ',{}' '\n' \
        | awk -F: '/"listen_port"/ {gsub(/[^0-9]/, "", $2); print $2; exit}'
}

write_cache() {
    umask 077
    echo "$PORT" > "$CACHE_FILE"
}

wait_for_qbt_webui() {
    local attempt

    for ((attempt = 1; attempt <= 12; attempt++)); do
        if curl -fsS --max-time 5 "$QBITTORRENT_URL/api/v2/app/version" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done

    return 1
}

restart_qbt_container() {
    if [[ -z "${QBT_CONTAINER_NAME:-}" ]]; then
        log "WARNING: QBT_CONTAINER_NAME is not set; qBittorrent will use the new port after its next restart"
        return 0
    fi

    require_command docker

    log "Restarting qBittorrent container $QBT_CONTAINER_NAME to apply listen port $PORT"
    docker restart "$QBT_CONTAINER_NAME" >/dev/null

    if ! wait_for_qbt_webui; then
        log "ERROR: qBittorrent Web UI did not become reachable after restarting $QBT_CONTAINER_NAME"
        return 1
    fi

    login_qbt

    if [[ "$(get_qbt_listen_port || true)" != "$PORT" ]]; then
        log "ERROR: qBittorrent reported a different port after restarting $QBT_CONTAINER_NAME"
        return 1
    fi
}

container_network_mode() {
    docker inspect -f '{{.HostConfig.NetworkMode}}' "$QBT_CONTAINER_NAME" 2>/dev/null || true
}

resolve_container_ip() {
    local networks

    networks="$(docker inspect -f '{{range $name, $network := .NetworkSettings.Networks}}{{printf "%s=%s\n" $name $network.IPAddress}}{{end}}' "$QBT_CONTAINER_NAME" 2>/dev/null || true)"

    [[ -n "$networks" ]] || return 1

    awk -F= -v wanted="${QBT_NETWORK_NAME:-}" '
        NF != 2 || $2 == "" { next }
        first == "" { first = $2 }
        wanted != "" && $1 == wanted {
            print $2
            found = 1
            exit
        }
        END {
            if (!found && first != "") {
                print first
            }
        }
    ' <<< "$networks"
}

ensure_qbt_dnat_chain() {
    nft list table ip proton_nat >/dev/null 2>&1 || nft add table ip proton_nat
    nft list chain ip proton_nat prerouting >/dev/null 2>&1 || \
        nft 'add chain ip proton_nat prerouting { type nat hook prerouting priority dstnat; policy accept; }'
}

dnat_rule_present() {
    local proto="$1"

    nft list chain ip proton_nat prerouting 2>/dev/null \
        | grep -F "${proto} dport ${PORT} dnat to ${CONTAINER_IP}:${QBT_INTERNAL_PORT}" >/dev/null 2>&1
}

refresh_qbt_dnat() {
    local network_mode

    if [[ -z "${QBT_CONTAINER_NAME:-}" ]]; then
        return 0
    fi

    require_command docker
    require_command nft

    network_mode="$(container_network_mode)"
    if [[ "$network_mode" == "host" ]]; then
        if [[ -x "$DNAT_CLEANUP_SCRIPT" ]]; then
            "$DNAT_CLEANUP_SCRIPT" || true
        fi
        log "qBittorrent container $QBT_CONTAINER_NAME uses host networking; DNAT refresh skipped"
        return 0
    fi

    CONTAINER_IP="$(resolve_container_ip || true)"
    if [[ -z "$CONTAINER_IP" ]]; then
        log "ERROR: Could not resolve a container IP for $QBT_CONTAINER_NAME"
        return 1
    fi

    if dnat_rule_present tcp && dnat_rule_present udp; then
        return 0
    fi

    if [[ -x "$DNAT_CLEANUP_SCRIPT" ]]; then
        "$DNAT_CLEANUP_SCRIPT" || true
    fi

    ensure_qbt_dnat_chain
    nft add rule ip proton_nat prerouting tcp dport "$PORT" dnat to "${CONTAINER_IP}:${QBT_INTERNAL_PORT}" comment "qbt-dnat"
    nft add rule ip proton_nat prerouting udp dport "$PORT" dnat to "${CONTAINER_IP}:${QBT_INTERNAL_PORT}" comment "qbt-dnat"
    DNAT_CHANGED=1
    log "Updated qBittorrent DNAT: public port $PORT -> ${CONTAINER_IP}:${QBT_INTERNAL_PORT}"
}

login_qbt

CURRENT_QBT_PORT="$(get_qbt_listen_port || true)"
PORT_CHANGED=0
DNAT_CHANGED=0

if [[ "$CURRENT_QBT_PORT" != "$PORT" ]]; then
    log "Updating qBittorrent port -> $PORT"

    curl -fsS -b "$COOKIE_JAR" -X POST \
        --data 'json={"random_port":false}' \
        "$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null

    curl -fsS -b "$COOKIE_JAR" -X POST \
        --data "json={\"listen_port\":$PORT}" \
        "$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null

    APPLIED_PORT="$(get_qbt_listen_port || true)"

    if [[ "$APPLIED_PORT" != "$PORT" ]]; then
        log "ERROR: qBittorrent did not apply port $PORT (reported: ${APPLIED_PORT:-unknown})"
        exit 1
    fi

    PORT_CHANGED=1
fi

if (( PORT_CHANGED )); then
    restart_qbt_container
fi

refresh_qbt_dnat
write_cache

if (( PORT_CHANGED )); then
    log "qBittorrent updated successfully"
elif (( DNAT_CHANGED )); then
    log "qBittorrent DNAT refreshed successfully"
else
    log "qBittorrent already using port $PORT"
fi
