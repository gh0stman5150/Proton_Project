#!/usr/bin/env bash
# Deprecated: systemd units use proton-port-forward-safe.sh.

set -euo pipefail

########################################
# CONFIG
########################################
VPN_INTERFACE="wg0"
NATPMP_GATEWAY="10.2.0.1"
STATE_FILE="/usr/local/bin/proton/proton-port.state"
LOG_TAG="proton-port"
CHECK_INTERVAL=30
MAX_FAILURES=3

########################################

log() {
    echo "$(date '+%F %T') | $*" | systemd-cat -t "$LOG_TAG"
}

get_ip() {
    ip -4 addr show "$VPN_INTERFACE" 2>/dev/null \
        | awk '/inet / {print $2}' | cut -d/ -f1 || true
}

request_port() {
    natpmpc -a 1 0 tcp 60 -g "$NATPMP_GATEWAY" 2>/dev/null
}

extract_port() {
    grep -oP 'Mapped public port \K[0-9]+' || true
}

save_port() {
    echo "$1" > "$STATE_FILE"
}

reconnect() {
    log "Recycling WireGuard tunnel..."
    /usr/local/bin/proton/proton-wg-up.sh
    sleep 5
}

########################################

log "Starting WireGuard port forward loop..."

LAST_IP=""
FAILURES=0

while true; do

    IP=$(get_ip)

    if [[ -z "$IP" ]]; then
        log "No VPN IP, reconnecting..."
        reconnect
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if [[ "$IP" != "$LAST_IP" ]]; then
        log "VPN IP changed: $LAST_IP → $IP"
        LAST_IP="$IP"
        FAILURES=0
    fi

    log "Requesting port..."

    OUT=$(request_port || true)
    PORT=$(echo "$OUT" | extract_port)

    if [[ -n "$PORT" ]]; then
        log "Got port: $PORT"
        save_port "$PORT"

        /usr/local/bin/proton/proton-qbittorrent-sync.sh || true
        FAILURES=0
    else
        ((FAILURES++))
        log "Port request failed ($FAILURES/$MAX_FAILURES)"

        if (( FAILURES >= MAX_FAILURES )); then
            log "Too many failures → reconnecting tunnel"
            reconnect
            FAILURES=0
            LAST_IP=""
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
