#!/usr/bin/env bash
set -euo pipefail

WG_PROFILE="${WG_PROFILE:-proton}"
STATE_DIR="${STATE_DIR:-/run/proton}"
WG_RUNTIME_DIR="${WG_RUNTIME_DIR:-/etc/wireguard/proton-runtime}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/${WG_PROFILE}.conf}"
FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"
VPN_FWMARK="${VPN_FWMARK:-0xca6c}"
VPN_TABLE="${VPN_TABLE:-51820}"

if ! command -v wg-quick >/dev/null 2>&1; then
    echo "ERROR: Required command 'wg-quick' is not installed." >&2
    exit 1
fi

if [[ -f "$SERVER_SELECTION_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$SERVER_SELECTION_FILE"
    WG_PROFILE="${SELECTED_WG_PROFILE:-$WG_PROFILE}"
    WG_CONFIG="${SELECTED_CONFIG:-$WG_CONFIG}"
    FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"
fi

# Remove policy routing before tearing down the interface so the kernel
# does not briefly try to route fwmark'd packets through a gone interface.
ip rule del fwmark "$VPN_FWMARK" lookup "$VPN_TABLE" priority 100 2>/dev/null || true
ip route flush table "$VPN_TABLE" 2>/dev/null || true

if [[ -f "$FILTERED_CONFIG_PATH" ]]; then
    wg-quick down "$FILTERED_CONFIG_PATH" || true
elif [[ -f "$WG_CONFIG" ]]; then
    wg-quick down "$WG_CONFIG" || true
else
    wg-quick down "$WG_PROFILE" || true
fi