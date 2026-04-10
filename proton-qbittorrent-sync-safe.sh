#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${QBITTORRENT_ENV_FILE:-/etc/proton/qbittorrent.env}"
STATE_FILE="${STATE_FILE:-/run/proton/proton-port.state}"
CACHE_FILE="${CACHE_FILE:-/run/proton/qbt-port.cache}"
DNAT_CLEANUP_SCRIPT="${DNAT_CLEANUP_SCRIPT:-${SCRIPT_DIR}/proton-qbt-dnat-cleanup.sh}"
QBT_COMMON_SCRIPT="${QBT_COMMON_SCRIPT:-${SCRIPT_DIR}/proton-qbittorrent-common.sh}"
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

for cmd in awk chmod curl mkdir mktemp rm sleep stat systemd-cat tr; do
    require_command "$cmd"
done

ensure_directory() {
    local dir="$1"
    local mode="${2:-}"
    local created=0

    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        created=1
    fi

    if (( created )) && [[ -n "$mode" ]]; then
        chmod "$mode" "$dir"
    fi
}

if [[ ! -f "$QBT_COMMON_SCRIPT" ]]; then
    log "ERROR: qBittorrent helper script not found: $QBT_COMMON_SCRIPT"
    exit 1
fi

# shellcheck disable=SC1090
source "$QBT_COMMON_SCRIPT"
qbt_source_env_file "$ENV_FILE"

QBT_INTERNAL_PORT="${QBT_INTERNAL_PORT:-6881}"
QBT_PORT_APPLY_MODE="${QBT_PORT_APPLY_MODE:-compose-recreate}"
QBT_PORT_ENV_FILE="${QBT_PORT_ENV_FILE:-/etc/proton/qbittorrent-port.env}"
QBT_COMPOSE_PROJECT_DIR="${QBT_COMPOSE_PROJECT_DIR:-}"
QBT_COMPOSE_SERVICE="${QBT_COMPOSE_SERVICE:-qbittorrent}"

case "$QBT_PORT_APPLY_MODE" in
compose-recreate | legacy-dnat)
    ;;
*)
    log "ERROR: Unsupported QBT_PORT_APPLY_MODE '$QBT_PORT_APPLY_MODE'"
    exit 1
    ;;
esac

ensure_directory "$CACHE_DIR" 700

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

write_cache() {
    umask 077
    echo "$PORT" > "$CACHE_FILE"
}

read_published_port() {
    awk -F= '/^QBT_PUBLISHED_PORT=/ {print $2; exit}' "$QBT_PORT_ENV_FILE" 2>/dev/null || true
}

write_published_port_value() {
    local value="$1"
    local port_dir="${QBT_PORT_ENV_FILE%/*}"

    if [[ "$port_dir" == "$QBT_PORT_ENV_FILE" ]]; then
        port_dir="."
    fi

    ensure_directory "$port_dir" 700
    umask 077
    {
        echo "# Managed by proton-qbittorrent-sync-safe.sh"
        echo "QBT_PUBLISHED_PORT=$value"
    } > "$QBT_PORT_ENV_FILE"
    chmod 600 "$QBT_PORT_ENV_FILE"
}

write_published_port() {
    write_published_port_value "$PORT"
}

disable_random_port() {
    curl -fsS -b "$COOKIE_JAR" -X POST \
        --data 'json={"random_port":false}' \
        "$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null
}

set_qbt_listen_port() {
    curl -fsS -b "$COOKIE_JAR" -X POST \
        --data "json={\"listen_port\":$PORT}" \
        "$QBITTORRENT_URL/api/v2/app/setPreferences" >/dev/null
}

apply_qbt_listen_port() {
    local applied_port

    if [[ "$CURRENT_QBT_PORT" == "$PORT" ]]; then
        return 0
    fi

    log "Updating qBittorrent listen port -> $PORT"
    disable_random_port
    set_qbt_listen_port

    applied_port="$(qbt_get_listen_port "$COOKIE_JAR" || true)"
    if [[ "$applied_port" != "$PORT" ]]; then
        log "ERROR: qBittorrent did not apply port $PORT (reported: ${applied_port:-unknown})"
        exit 1
    fi

    LISTEN_PORT_CHANGED=1
}

require_compose_mode_ready() {
    require_command docker

    if [[ -z "$QBT_COMPOSE_PROJECT_DIR" ]]; then
        log "ERROR: QBT_COMPOSE_PROJECT_DIR is required in compose-recreate mode"
        return 1
    fi

    if [[ ! -d "$QBT_COMPOSE_PROJECT_DIR" ]]; then
        log "ERROR: Compose project directory not found: $QBT_COMPOSE_PROJECT_DIR"
        return 1
    fi

    if [[ -z "$QBT_COMPOSE_SERVICE" ]]; then
        log "ERROR: QBT_COMPOSE_SERVICE is required in compose-recreate mode"
        return 1
    fi
}

recreate_qbt_service_compose() {
    log "Recreating Compose service $QBT_COMPOSE_SERVICE in $QBT_COMPOSE_PROJECT_DIR for published port $PORT"
    docker compose --project-directory "$QBT_COMPOSE_PROJECT_DIR" up -d --force-recreate --no-deps "$QBT_COMPOSE_SERVICE" >/dev/null

    if ! qbt_wait_for_webui 12 5; then
        log "ERROR: qBittorrent Web UI did not become reachable after recreating $QBT_COMPOSE_SERVICE"
        return 1
    fi

    if ! qbt_login "$COOKIE_JAR"; then
        log "ERROR: Authentication failed after recreating $QBT_COMPOSE_SERVICE"
        return 1
    fi

    if [[ "$(qbt_get_listen_port "$COOKIE_JAR" || true)" != "$PORT" ]]; then
        log "ERROR: qBittorrent reported a different port after recreating $QBT_COMPOSE_SERVICE"
        return 1
    fi
}

restart_qbt_container_legacy() {
    if [[ -z "${QBT_CONTAINER_NAME:-}" ]]; then
        log "WARNING: QBT_CONTAINER_NAME is not set; qBittorrent will use the new port after its next restart"
        return 0
    fi

    require_command docker

    log "Restarting qBittorrent container $QBT_CONTAINER_NAME to apply listen port $PORT"
    docker restart "$QBT_CONTAINER_NAME" >/dev/null

    if ! qbt_wait_for_webui 12 5; then
        log "ERROR: qBittorrent Web UI did not become reachable after restarting $QBT_CONTAINER_NAME"
        return 1
    fi

    if ! qbt_login "$COOKIE_JAR"; then
        log "ERROR: Authentication failed after restarting $QBT_CONTAINER_NAME"
        return 1
    fi

    if [[ "$(qbt_get_listen_port "$COOKIE_JAR" || true)" != "$PORT" ]]; then
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

refresh_qbt_dnat_legacy() {
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

if ! qbt_login "$COOKIE_JAR"; then
    log "ERROR: Authentication failed"
    exit 1
fi

CURRENT_QBT_PORT="$(qbt_get_listen_port "$COOKIE_JAR" || true)"
CURRENT_PUBLISHED_PORT="$(read_published_port || true)"
LISTEN_PORT_CHANGED=0
PUBLISHED_PORT_CHANGED=0
DNAT_CHANGED=0

if [[ -n "$CURRENT_PUBLISHED_PORT" && ! "$CURRENT_PUBLISHED_PORT" =~ ^[0-9]+$ ]]; then
    log "ERROR: Invalid QBT_PUBLISHED_PORT value in $QBT_PORT_ENV_FILE: $CURRENT_PUBLISHED_PORT"
    exit 1
fi

apply_qbt_listen_port

case "$QBT_PORT_APPLY_MODE" in
compose-recreate)
    if [[ "$CURRENT_PUBLISHED_PORT" != "$PORT" ]]; then
        require_compose_mode_ready || exit 1
        log "Updating qBittorrent published port artifact -> $PORT"
        write_published_port
        PUBLISHED_PORT_CHANGED=1
        if ! recreate_qbt_service_compose; then
            if [[ -n "$CURRENT_PUBLISHED_PORT" ]]; then
                write_published_port_value "$CURRENT_PUBLISHED_PORT"
            else
                rm -f "$QBT_PORT_ENV_FILE"
            fi
            exit 1
        fi
    fi
    ;;
legacy-dnat)
    if (( LISTEN_PORT_CHANGED )); then
        restart_qbt_container_legacy || exit 1
    fi
    refresh_qbt_dnat_legacy || exit 1
    ;;
esac

write_cache

if (( PUBLISHED_PORT_CHANGED )); then
    log "qBittorrent updated successfully with Compose recreation"
elif (( LISTEN_PORT_CHANGED )); then
    log "qBittorrent listen port corrected without published-port changes"
elif (( DNAT_CHANGED )); then
    log "qBittorrent legacy DNAT refreshed successfully"
else
    log "qBittorrent already using port $PORT"
fi
