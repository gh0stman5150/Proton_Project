#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-loop}"
WG_PROFILE="${WG_PROFILE:-proton}"
VPN_INTERFACE="${VPN_INTERFACE:-$WG_PROFILE}"
NATPMP_GATEWAY="${NATPMP_GATEWAY:-10.2.0.1}"
STATE_DIR="${STATE_DIR:-/run/proton}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/proton-port.state}"
LOG_TAG="${LOG_TAG:-proton-port}"
CHECK_INTERVAL="${CHECK_INTERVAL:-45}"
MAX_FAILURES="${MAX_FAILURES:-5}"
PORT_LEASE_SECONDS="${PORT_LEASE_SECONDS:-60}"
NATPMP_TIMEOUT_SECONDS="${NATPMP_TIMEOUT_SECONDS:-15}"
WG_UP_SCRIPT="${WG_UP_SCRIPT:-/usr/local/bin/proton/proton-wg-up-safe.sh}"
QBITTORRENT_SYNC_SCRIPT="${QBITTORRENT_SYNC_SCRIPT:-/usr/local/bin/proton/proton-qbittorrent-sync-safe.sh}"
SERVER_POOL_ENABLED="${SERVER_POOL_ENABLED:-auto}"
SERVER_MANAGER_SCRIPT="${SERVER_MANAGER_SCRIPT:-/usr/local/bin/proton/proton-server-manager.sh}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
RECOVERY_LOCK_FILE="${RECOVERY_LOCK_FILE:-${STATE_DIR}/recovery.lock}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"
PF_CAPABLE_PROFILES_FILE="${PF_CAPABLE_PROFILES_FILE:-/etc/proton/pf-capable-profiles.tsv}"
CURRENT_WG_PROFILE="$WG_PROFILE"

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

for cmd in awk chmod cut flock grep ip mkdir natpmpc rm systemd-cat timeout; do
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

ensure_directory "$STATE_DIR" 700

case "$MODE" in
    loop|once)
        ;;
    *)
        log "ERROR: Unsupported mode '$MODE' (expected 'loop' or 'once')"
        exit 1
        ;;
esac

server_pool_requested() {
    case "$SERVER_POOL_ENABLED" in
        1|true|yes|on)
            return 0
            ;;
        auto)
            compgen -G "$WG_POOL_DIR/*.conf" >/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

load_selected_server() {
    if ! server_pool_requested; then
        CURRENT_WG_PROFILE="$WG_PROFILE"
        return 0
    fi

    if [[ -f "$SERVER_SELECTION_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SERVER_SELECTION_FILE"
        CURRENT_WG_PROFILE="${SELECTED_WG_PROFILE:-$WG_PROFILE}"
        VPN_INTERFACE="${SELECTED_VPN_INTERFACE:-$VPN_INTERFACE}"
    else
        CURRENT_WG_PROFILE="$WG_PROFILE"
    fi
}

profile_in_state_file() {
    local file="$1"
    local profile="$2"

    [[ -f "$file" ]] || return 1

    awk -F '\t' -v profile="$profile" '
        $1 == profile { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$file"
}

profile_is_known_capable() {
    local profile="$1"

    [[ -n "$profile" ]] || return 1
    profile_in_state_file "$PF_CAPABLE_PROFILES_FILE" "$profile"
}

get_ip() {
    load_selected_server
    ip -4 addr show "$VPN_INTERFACE" 2>/dev/null \
        | awk '/inet / {print $2}' | cut -d/ -f1 || true
}

request_port() {
    timeout "${NATPMP_TIMEOUT_SECONDS}s" \
        natpmpc -a 1 0 udp "$PORT_LEASE_SECONDS" -g "$NATPMP_GATEWAY" >/dev/null 2>&1
    timeout "${NATPMP_TIMEOUT_SECONDS}s" \
        natpmpc -a 1 0 tcp "$PORT_LEASE_SECONDS" -g "$NATPMP_GATEWAY" 2>/dev/null
}

refresh_port() {
    local port="$1"

    timeout "${NATPMP_TIMEOUT_SECONDS}s" \
        natpmpc -a 1 0 udp "$PORT_LEASE_SECONDS" -g "$NATPMP_GATEWAY" >/dev/null 2>&1
    timeout "${NATPMP_TIMEOUT_SECONDS}s" \
        natpmpc -a 1 "$port" tcp "$PORT_LEASE_SECONDS" -g "$NATPMP_GATEWAY" 2>/dev/null
}

extract_port() {
    awk '/Mapped public port/ {print $4; exit}' || true
}

save_state() {
    umask 077
    {
        echo "CURRENT_PORT=$1"
        echo "CURRENT_IP=$2"
    } > "$STATE_FILE"
}

load_state_port() {
    awk -F= '/^CURRENT_PORT=/ {print $2; exit}' "$STATE_FILE" 2>/dev/null || true
}

load_state_ip() {
    awk -F= '/^CURRENT_IP=/ {print $2; exit}' "$STATE_FILE" 2>/dev/null || true
}

clear_state() {
    rm -f "$STATE_FILE"
}

reconnect() {
    local failed_profile="${1:-$CURRENT_WG_PROFILE}"

    (
        flock -n 200 || {
            log "Recovery lock busy, skipping reconnect"
            exit 0
        }

        log "Recycling WireGuard tunnel..."

        if [[ -z "$failed_profile" ]]; then
            load_selected_server
            failed_profile="$CURRENT_WG_PROFILE"
        fi

        if server_pool_requested && [[ -x "$SERVER_MANAGER_SCRIPT" ]]; then
            "$SERVER_MANAGER_SCRIPT" mark-bad "$failed_profile" "port-forward-failures" >/dev/null 2>&1 || true
        fi

        clear_state
        "$WG_UP_SCRIPT"
        sleep 5
    ) 200>"$RECOVERY_LOCK_FILE"
}

log "Starting WireGuard port forward loop..."

LAST_IP="$(load_state_ip)"
CURRENT_PORT="$(load_state_port)"
FAILURES=0

load_selected_server

if [[ "$MODE" == "once" ]]; then
    IP="$(get_ip)"

    if [[ -z "$IP" ]]; then
        log "No VPN IP; one-shot NAT-PMP refresh cannot run"
        exit 1
    fi

    if [[ "$IP" != "$LAST_IP" ]]; then
        log "VPN IP changed: ${LAST_IP:-unknown} -> $IP"
        LAST_IP="$IP"
        CURRENT_PORT=""
    fi

    if [[ -n "$CURRENT_PORT" ]]; then
        log "Refreshing port $CURRENT_PORT..."
        OUT="$(refresh_port "$CURRENT_PORT" || true)"
    else
        log "Requesting new port..."
        OUT="$(request_port || true)"
    fi

    PORT="$(echo "$OUT" | extract_port)"

    if [[ -z "$PORT" ]]; then
        log "One-shot NAT-PMP refresh failed"
        if [[ -n "$OUT" ]]; then
            log "Last NAT-PMP output: ${OUT//$'\n'/; }"
        fi
        exit 1
    fi

    log "Got port: $PORT"
    save_state "$PORT" "$IP"

    if ! "$QBITTORRENT_SYNC_SCRIPT"; then
        log "ERROR: qBittorrent port sync failed during one-shot NAT-PMP refresh"
        exit 1
    fi

    exit 0
fi

while true; do
    IP="$(get_ip)"

    if [[ -z "$IP" ]]; then
        log "No VPN IP, reconnecting..."
        reconnect "$CURRENT_WG_PROFILE"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if [[ "$IP" != "$LAST_IP" ]]; then
        log "VPN IP changed: ${LAST_IP:-unknown} -> $IP"
        LAST_IP="$IP"
        CURRENT_PORT=""
        FAILURES=0
    fi

    if [[ -n "$CURRENT_PORT" ]]; then
        log "Refreshing port $CURRENT_PORT..."
        OUT="$(refresh_port "$CURRENT_PORT" || true)"
    else
        log "Requesting new port..."
        OUT="$(request_port || true)"
    fi

    PORT="$(echo "$OUT" | extract_port)"

    if [[ -n "$PORT" ]]; then
        log "Got port: $PORT"
        CURRENT_PORT="$PORT"
        save_state "$PORT" "$IP"
        if server_pool_requested && [[ -x "$SERVER_MANAGER_SCRIPT" ]]; then
            "$SERVER_MANAGER_SCRIPT" mark-capable "$CURRENT_WG_PROFILE" "$PORT" >/dev/null 2>&1 || true
        fi
        if ! "$QBITTORRENT_SYNC_SCRIPT"; then
            log "WARNING: qBittorrent port sync failed"
        fi
        FAILURES=0
    else
        FAILURES=$((FAILURES + 1))
        log "Port request failed ($FAILURES/$MAX_FAILURES)"
        if [[ -n "$OUT" ]]; then
            log "Last NAT-PMP output: ${OUT//$'\n'/; }"
        fi
        CURRENT_PORT=""

        if (( FAILURES >= MAX_FAILURES )); then
            if server_pool_requested && [[ -x "$SERVER_MANAGER_SCRIPT" ]]; then
                if profile_is_known_capable "$CURRENT_WG_PROFILE"; then
                    log "Profile $CURRENT_WG_PROFILE previously forwarded successfully; treating repeated NAT-PMP failures as transient"
                else
                    "$SERVER_MANAGER_SCRIPT" mark-incapable "$CURRENT_WG_PROFILE" "natpmp-timeout" >/dev/null 2>&1 || true
                fi
            fi
            log "Too many failures on ${CURRENT_WG_PROFILE:-$WG_PROFILE} -> reconnecting tunnel"
            reconnect "$CURRENT_WG_PROFILE"
            FAILURES=0
            LAST_IP=""
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
