#!/usr/bin/env bash
set -euo pipefail

LOG_TAG="${LOG_TAG:-proton-wg}"
WG_PROFILE="${WG_PROFILE:-proton}"
VPN_INTERFACE="${VPN_INTERFACE:-$WG_PROFILE}"
STATE_DIR="${STATE_DIR:-/run/proton}"
WG_RUNTIME_DIR="${WG_RUNTIME_DIR:-/etc/wireguard/proton-runtime}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/${WG_PROFILE}.conf}"
FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"
VPN_FWMARK="${VPN_FWMARK:-0xca6c}"
VPN_TABLE="${VPN_TABLE:-51820}"
DOCKER_NETWORK_CIDR="${DOCKER_NETWORK_CIDR:-}"
KILLSWITCH_BACKEND="${KILLSWITCH_BACKEND:-auto}"
LAN_IF="${LAN_IF:-}"
LAN_CIDR="${LAN_CIDR:-}"
DOCKER_LOCAL_RULE_PRIORITY="${DOCKER_LOCAL_RULE_PRIORITY:-108}"
DOCKER_LAN_RULE_PRIORITY="${DOCKER_LAN_RULE_PRIORITY:-109}"
DOCKER_VPN_RULE_PRIORITY="${DOCKER_VPN_RULE_PRIORITY:-110}"
MANAGE_RESOLVED_DNS="${MANAGE_RESOLVED_DNS:-auto}"
RESOLVED_DNS_ROUTE_DOMAIN="${RESOLVED_DNS_ROUTE_DOMAIN:-~.}"

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
		log "ERROR: Required command '$cmd' is not installed."
		exit 1
	fi
}

resolved_dns_enabled() {
	case "$MANAGE_RESOLVED_DNS" in
	1 | true | yes | on)
		if command -v resolvectl >/dev/null 2>&1; then
			return 0
		fi
		log "ERROR: MANAGE_RESOLVED_DNS is enabled but resolvectl is not installed."
		exit 1
		;;
	auto)
		command -v resolvectl >/dev/null 2>&1
		;;
	*)
		return 1
		;;
	esac
}

teardown_resolved_dns() {
	local ifname="$1"

	resolved_dns_enabled || return 0
	[[ -n "$ifname" ]] || return 0

	resolvectl revert "$ifname" >/dev/null 2>&1 || true
	resolvectl flush-caches >/dev/null 2>&1 || true
}

detect_lan_cidr() {
	if [[ -n "$LAN_CIDR" ]]; then
		return 0
	fi

	if [[ -z "$LAN_IF" ]]; then
		LAN_IF="$(ip route | awk '/default/ {print $5; exit}')"
	fi

	if [[ -n "$LAN_IF" ]]; then
		LAN_CIDR="$(ip -4 route show dev "$LAN_IF" | awk '$1 ~ /^[0-9]/ && $1 != "default" {print $1; exit}')"
	fi
}

for cmd in ip wg-quick; do
	require_command "$cmd"
done

if [[ -f "$SERVER_SELECTION_FILE" ]]; then
	# shellcheck disable=SC1090
	source "$SERVER_SELECTION_FILE"
	WG_PROFILE="${SELECTED_WG_PROFILE:-$WG_PROFILE}"
	VPN_INTERFACE="${SELECTED_VPN_INTERFACE:-$VPN_INTERFACE}"
	WG_CONFIG="${SELECTED_CONFIG:-$WG_CONFIG}"
	FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"
fi

# Remove policy routing before tearing down the interface so the kernel
# does not briefly try to route fwmark'd packets through a gone interface.
ip rule del fwmark "$VPN_FWMARK" lookup "$VPN_TABLE" priority 100 2>/dev/null || true
ip rule del not fwmark "$VPN_FWMARK" lookup "$VPN_TABLE" priority 100 2>/dev/null || true
ip rule del table main suppress_prefixlength 0 priority 99 2>/dev/null || true
ip route flush table "$VPN_TABLE" 2>/dev/null || true
if [[ -n "$DOCKER_NETWORK_CIDR" ]]; then
	detect_lan_cidr
	ip rule del from "$DOCKER_NETWORK_CIDR" to "$DOCKER_NETWORK_CIDR" lookup main priority "$DOCKER_LOCAL_RULE_PRIORITY" 2>/dev/null || true
	if [[ -n "$LAN_CIDR" ]]; then
		ip rule del from "$DOCKER_NETWORK_CIDR" to "$LAN_CIDR" lookup main priority "$DOCKER_LAN_RULE_PRIORITY" 2>/dev/null || true
	fi
	ip rule del from "$DOCKER_NETWORK_CIDR" lookup "$VPN_TABLE" priority "$DOCKER_VPN_RULE_PRIORITY" 2>/dev/null || true
fi

teardown_resolved_dns "$VPN_INTERFACE"

if [[ -f "$FILTERED_CONFIG_PATH" ]]; then
	wg-quick down "$FILTERED_CONFIG_PATH" || true
elif [[ -f "$WG_CONFIG" ]]; then
	wg-quick down "$WG_CONFIG" || true
else
	wg-quick down "$WG_PROFILE" || true
fi
