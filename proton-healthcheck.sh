#!/usr/bin/env bash

set -euo pipefail

QBITTORRENT_ENV_FILE="${QBITTORRENT_ENV_FILE:-/etc/proton/qbittorrent.env}"
QBITTORRENT_URL="${QBITTORRENT_URL:-}"
SERVER_MANAGER_SCRIPT="${SERVER_MANAGER_SCRIPT:-/usr/local/bin/proton/proton-server-manager.sh}"

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' is not installed." >&2
        exit 1
    fi
}

for cmd in curl ip natpmpc stat systemd-cat; do
    require_command "$cmd"
done

if [[ ! -f "$QBITTORRENT_ENV_FILE" ]]; then
    echo "ERROR: qBittorrent env file not found: $QBITTORRENT_ENV_FILE." >&2
    exit 1
fi

ENV_MODE="$(stat -c '%a' "$QBITTORRENT_ENV_FILE")"
ENV_OWNER="$(stat -c '%u' "$QBITTORRENT_ENV_FILE")"

if [[ "$ENV_MODE" != "600" ]]; then
    echo "ERROR: $QBITTORRENT_ENV_FILE must have mode 600." >&2
    exit 1
fi

if [[ "$ENV_OWNER" != "0" ]]; then
    echo "ERROR: $QBITTORRENT_ENV_FILE must be owned by root." >&2
    exit 1
fi

if [[ -z "$QBITTORRENT_URL" ]]; then
    # shellcheck disable=SC1090
    source "$QBITTORRENT_ENV_FILE"
fi

: "${QBITTORRENT_URL:?QBITTORRENT_URL must be set in ${QBITTORRENT_ENV_FILE}}"
QBITTORRENT_URL="${QBITTORRENT_URL%/}"

if ! curl -fsS --max-time 5 "$QBITTORRENT_URL/api/v2/app/version" >/dev/null; then
    echo "WARNING: qBittorrent Web API is not reachable at $QBITTORRENT_URL; continuing and relying on the sync loop to retry later." >&2
fi

: "${QBITTORRENT_USER:?Missing QBITTORRENT_USER}"
: "${QBITTORRENT_PASS:?Missing QBITTORRENT_PASS}"

login_cookie() {
    local response
    response="$(curl -fsS -i \
        --data "username=$QBITTORRENT_USER&password=$QBITTORRENT_PASS" \
        "$QBITTORRENT_URL/api/v2/auth/login" || true)"

    printf '%s' "$response" | grep -Fi set-cookie | cut -d' ' -f2 | tr -d '\r'
}

has_active_transfers() {
    local cookie="$1"
    local active_json

    active_json="$(curl -fsS --cookie "$cookie" \
        "$QBITTORRENT_URL/api/v2/torrents/info?filter=active" || true)"

    [[ -n "$active_json" && "$active_json" != "[]" ]]
}

combined_speed_bps() {
    local cookie="$1"
    local transfer_json

    transfer_json="$(curl -fsS --cookie "$cookie" \
        "$QBITTORRENT_URL/api/v2/transfer/info" || true)"

    printf '%s' "$transfer_json" | awk -F '[:,}]' '
        {
            for (i = 1; i <= NF; i++) {
                gsub(/[ "]/, "", $i)
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

recover() {
    local speed="$1"

    log "Throughput stayed below threshold at ${speed} B/s; restarting Proton services"

    if [[ -x "$SERVER_MANAGER_SCRIPT" ]]; then
        "$SERVER_MANAGER_SCRIPT" mark-bad "" "low-throughput-${speed}" >/dev/null 2>&1 || true
    fi

    systemctl restart proton-killswitch.service proton-wg.service proton-port-forward.service
}

LOW_SPEED_COUNT=0

log "Starting throughput healthcheck loop..."

while true; do
    COOKIE="$(login_cookie)"

    if [[ -z "$COOKIE" ]]; then
        LOW_SPEED_COUNT=0
        log "qBittorrent login failed during healthcheck; retrying later"
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if ! has_active_transfers "$COOKIE"; then
        LOW_SPEED_COUNT=0
        sleep "$CHECK_INTERVAL"
        continue
    fi

    SPEED_BPS="$(combined_speed_bps "$COOKIE")"

    if [[ -z "$SPEED_BPS" ]]; then
        LOW_SPEED_COUNT=0
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if (( SPEED_BPS < MIN_COMBINED_SPEED_BPS )); then
        ((LOW_SPEED_COUNT++))
        log "Low throughput detected (${SPEED_BPS} B/s, ${LOW_SPEED_COUNT}/${MAX_LOW_SPEED_CHECKS})"

        if (( LOW_SPEED_COUNT >= MAX_LOW_SPEED_CHECKS )); then
            recover "$SPEED_BPS"
            LOW_SPEED_COUNT=0
        fi
    else
        LOW_SPEED_COUNT=0
    fi

    sleep "$CHECK_INTERVAL"
done