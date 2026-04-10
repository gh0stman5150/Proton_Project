#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TAG="${LOG_TAG:-proton-healthcheck}"
STATE_DIR="${STATE_DIR:-/run/proton}"
STATE_FILE="${STATE_FILE:-${STATE_DIR}/proton-port.state}"
RECOVERY_LOCK_FILE="${RECOVERY_LOCK_FILE:-${STATE_DIR}/recovery.lock}"
QBITTORRENT_ENV_FILE="${QBITTORRENT_ENV_FILE:-/etc/proton/qbittorrent.env}"
QBITTORRENT_SYNC_SCRIPT="${QBITTORRENT_SYNC_SCRIPT:-/usr/local/bin/proton/proton-qbittorrent-sync-safe.sh}"
PORT_FORWARD_SCRIPT="${PORT_FORWARD_SCRIPT:-/usr/local/bin/proton/proton-port-forward-safe.sh}"
SERVER_MANAGER_SCRIPT="${SERVER_MANAGER_SCRIPT:-/usr/local/bin/proton/proton-server-manager.sh}"
QBT_COMMON_SCRIPT="${QBT_COMMON_SCRIPT:-${SCRIPT_DIR}/proton-qbittorrent-common.sh}"

log() {
    local message
    message="$(date '+%F %T') | $*"

    if command -v systemd-cat >/dev/null 2>&1; then
        echo "$message" | systemd-cat -t "$LOG_TAG"
    else
        echo "$message" >&2
    fi
}

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' is not installed." >&2
        exit 1
    fi
}

for cmd in awk curl flock grep mktemp rm stat systemctl tr; do
    require_command "$cmd"
done

if [[ ! -f "$QBT_COMMON_SCRIPT" ]]; then
    echo "ERROR: qBittorrent helper script not found: $QBT_COMMON_SCRIPT" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$QBT_COMMON_SCRIPT"
qbt_source_env_file "$QBITTORRENT_ENV_FILE"

: "${QBITTORRENT_URL:?QBITTORRENT_URL must be set in ${QBITTORRENT_ENV_FILE}}"

if ! curl -fsS --max-time 5 "$QBITTORRENT_URL/api/v2/app/version" >/dev/null; then
    echo "WARNING: qBittorrent Web API is not reachable at $QBITTORRENT_URL; continuing and relying on the sync loop to retry later." >&2
fi

COOKIE_JAR="$(mktemp)"
cleanup() {
    rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

has_active_transfers() {
    local active_json

    active_json="$(curl -fsS -b "$COOKIE_JAR" \
        "$QBITTORRENT_URL/api/v2/torrents/info?filter=active" || true)"

    [[ -n "$active_json" && "$active_json" != "[]" ]]
}

combined_speed_bps() {
    local transfer_json

    transfer_json="$(curl -fsS -b "$COOKIE_JAR" \
        "$QBITTORRENT_URL/api/v2/transfer/info" || true)"

    printf '%s' "$transfer_json" | awk -F '[:,}]' '
        {
            for (i = 1; i <= NF; i++) {
                gsub(/[ "]/ , "", $i)
                if ($i == "dl_info_speed") {
                    dl = $(i + 1) + 0
                }
                if ($i == "up_info_speed") {
                    ul = $(i + 1) + 0
                }
            }
        }
        END { print dl + ul }
    '
}

has_current_port_state() {
    [[ -f "$STATE_FILE" ]] || return 1

    awk -F= '
        /^CURRENT_PORT=/ {
            found = ($2 != "")
            exit
        }
        END { exit found ? 0 : 1 }
    ' "$STATE_FILE"
}

with_recovery_lock() {
    local action="$1"
    shift

    (
        flock -n 201 || {
            log "Recovery lock busy, skipping ${action}"
            exit 99
        }
        "$@"
    ) 201>"$RECOVERY_LOCK_FILE"
}

perform_qb_sync_refresh() {
    local speed="$1"

    if [[ ! -x "$QBITTORRENT_SYNC_SCRIPT" ]]; then
        log "WARNING: qBittorrent sync script is not executable: $QBITTORRENT_SYNC_SCRIPT"
        return 1
    fi

    log "Throughput stayed below threshold at ${speed} B/s; refreshing qBittorrent port state"
    "$QBITTORRENT_SYNC_SCRIPT"
}

perform_natpmp_refresh() {
    local speed="$1"

    if [[ ! -x "$PORT_FORWARD_SCRIPT" ]]; then
        log "WARNING: Port-forward script is not executable: $PORT_FORWARD_SCRIPT"
        return 1
    fi

    log "Throughput stayed below threshold at ${speed} B/s; forcing a one-shot NAT-PMP refresh"
    "$PORT_FORWARD_SCRIPT" once
}

perform_full_recovery() {
    local speed="$1"

    log "Throughput stayed below threshold at ${speed} B/s after staged recovery; restarting Proton services"

    if [[ -x "$SERVER_MANAGER_SCRIPT" ]]; then
        "$SERVER_MANAGER_SCRIPT" mark-bad "" "low-throughput-${speed}" >/dev/null 2>&1 || true
    fi

    systemctl restart proton-killswitch.service proton-wg.service proton-port-forward.service
}

recover() {
    local speed="$1"
    local action_name=""
    local action_func=""
    local next_stage=0
    local rc

    while true; do
        case "$RECOVERY_STAGE" in
        0)
            if has_current_port_state; then
                action_name="qB sync refresh"
                action_func="perform_qb_sync_refresh"
                next_stage=1
                break
            fi

            log "Skipping qB sync refresh because no forwarded port is recorded; escalating to NAT-PMP refresh"
            RECOVERY_STAGE=1
            ;;
        1)
            action_name="NAT-PMP refresh"
            action_func="perform_natpmp_refresh"
            next_stage=2
            break
            ;;
        *)
            action_name="healthcheck recovery"
            action_func="perform_full_recovery"
            next_stage=0
            break
            ;;
        esac
    done

    if with_recovery_lock "$action_name" "$action_func" "$speed"; then
        RECOVERY_STAGE="$next_stage"
        return 0
    fi

    rc=$?
    if [[ "$rc" -eq 99 ]]; then
        return 0
    fi

    log "Recovery action '$action_name' failed with exit $rc"
    RECOVERY_STAGE="$next_stage"
    return 0
}

reset_recovery_state() {
    local reason="${1:-}"

    LOW_SPEED_COUNT=0
    if ((RECOVERY_STAGE != 0)) && [[ -n "$reason" ]]; then
        log "$reason"
    fi
    RECOVERY_STAGE=0
}

LOW_SPEED_COUNT=0
RECOVERY_STAGE=0

log "Starting throughput healthcheck loop..."

while true; do
    if ! qbt_login "$COOKIE_JAR"; then
        reset_recovery_state
        log "qBittorrent login failed during healthcheck; retrying later"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if ! has_active_transfers; then
        reset_recovery_state
        sleep "$CHECK_INTERVAL"
        continue
    fi

    SPEED_BPS="$(combined_speed_bps)"

    if [[ -z "$SPEED_BPS" ]]; then
        reset_recovery_state
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if ((SPEED_BPS < MIN_COMBINED_SPEED_BPS)); then
        ((LOW_SPEED_COUNT++))
        log "Low throughput detected (${SPEED_BPS} B/s, ${LOW_SPEED_COUNT}/${MAX_LOW_SPEED_CHECKS}, stage ${RECOVERY_STAGE})"

        if ((LOW_SPEED_COUNT >= MAX_LOW_SPEED_CHECKS)); then
            recover "$SPEED_BPS"
            LOW_SPEED_COUNT=0
        fi
    else
        reset_recovery_state "Throughput recovered; resetting staged recovery ladder"
    fi

    sleep "$CHECK_INTERVAL"
done
