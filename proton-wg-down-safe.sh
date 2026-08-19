#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_COMMON_SCRIPT="${PROTON_INSTANCE_COMMON_SCRIPT:-${SCRIPT_DIR}/proton-instance-common.sh}"
if [[ ! -f "$INSTANCE_COMMON_SCRIPT" ]]; then
	echo "ERROR: Proton instance helper not found: $INSTANCE_COMMON_SCRIPT" >&2
	exit 1
fi
# shellcheck disable=SC1090
source "$INSTANCE_COMMON_SCRIPT"
proton_instance_init "${1:-}"

LOG_TAG="${LOG_TAG:-proton-wg}"
WG_PROFILE="${WG_PROFILE:-proton}"
VPN_INTERFACE="${VPN_INTERFACE:-$WG_PROFILE}"
STATE_DIR="${STATE_DIR:-/run/proton}"
WG_RUNTIME_DIR="${WG_RUNTIME_DIR:-/etc/wireguard/proton-runtime}"
DOCKER_NETWORK_CIDR_STATE_FILE="${DOCKER_NETWORK_CIDR_STATE_FILE:-${STATE_DIR}/docker-network-cidr}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/${WG_PROFILE}.conf}"
FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"
VPN_FWMARK="${VPN_FWMARK:-0xca6c}"
VPN_TABLE="${VPN_TABLE:-51820}"
WG_IPV6_ENABLED="${WG_IPV6_ENABLED:-off}"
DOCKER_NETWORK_CIDR="${DOCKER_NETWORK_CIDR:-}"
DOCKER_NETWORK_CIDR6="${DOCKER_NETWORK_CIDR6:-}"
QBT_CONTAINER_NAME="${QBT_CONTAINER_NAME:-}"
QBT_NETWORK_NAME="${QBT_NETWORK_NAME:-}"
QBT_CONTAINER_IP_STATE_FILE="${QBT_CONTAINER_IP_STATE_FILE:-${STATE_DIR}/qbt-container-ip}"
QBT_CONTAINER_IP6_STATE_FILE="${QBT_CONTAINER_IP6_STATE_FILE:-${STATE_DIR}/qbt-container-ip6}"
KILLSWITCH_BACKEND="${KILLSWITCH_BACKEND:-auto}"
LAN_IF="${LAN_IF:-}"
LAN_CIDR="${LAN_CIDR:-}"
DOCKER_LOCAL_RULE_PRIORITY="${DOCKER_LOCAL_RULE_PRIORITY:-108}"
DOCKER_LAN_RULE_PRIORITY="${DOCKER_LAN_RULE_PRIORITY:-109}"
DOCKER_VPN_RULE_PRIORITY="${DOCKER_VPN_RULE_PRIORITY:-110}"
QBT_VPN_RULE_PRIORITY="${QBT_VPN_RULE_PRIORITY:-$DOCKER_VPN_RULE_PRIORITY}"
DOCKER_FALLBACK_VPN_RULE_PRIORITY="${DOCKER_FALLBACK_VPN_RULE_PRIORITY:-130}"
DOCKER_DEST_MAIN_RULE_PRIORITY="${DOCKER_DEST_MAIN_RULE_PRIORITY:-98}"
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

trim_field() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s\n' "$value"
}

normalize_ipv4_rule_source() {
	local value="$1"

	[[ -n "$value" ]] || return 1
	if [[ "$value" == */* ]]; then
		printf '%s\n' "$value"
	else
		printf '%s/32\n' "$value"
	fi
}

normalize_ipv6_rule_source() {
	local value="$1"

	value="$(trim_field "$value")"
	[[ "$value" == *:* ]] || return 1
	printf '%s/128\n' "${value%%/*}"
}

ipv6_enabled() {
	case "$WG_IPV6_ENABLED" in
	1 | true | yes | on)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

resolve_qbt_container_ip() {
	local networks=""
	local ip=""

	[[ -n "$QBT_CONTAINER_NAME" ]] || return 1
	command -v docker >/dev/null 2>&1 || return 1

	networks="$(docker inspect -f '{{range $name, $network := .NetworkSettings.Networks}}{{printf "%s=%s\n" $name $network.IPAddress}}{{end}}' "$QBT_CONTAINER_NAME" 2>/dev/null || true)"
	[[ -n "$networks" ]] || return 1

	if [[ -n "$QBT_NETWORK_NAME" ]]; then
		ip="$(awk -F= -v target="$QBT_NETWORK_NAME" '$1 == target && $2 != "" {print $2; exit}' <<<"$networks")"
	fi

	if [[ -z "$ip" ]]; then
		ip="$(awk -F= '$2 != "" {print $2; exit}' <<<"$networks")"
	fi

	[[ -n "$ip" ]] || return 1
	printf '%s\n' "$ip"
}

resolve_qbt_container_ipv6() {
	local networks=""
	local ip=""

	[[ -n "$QBT_CONTAINER_NAME" ]] || return 1
	command -v docker >/dev/null 2>&1 || return 1
	networks="$(docker inspect -f '{{range $name, $network := .NetworkSettings.Networks}}{{printf "%s=%s\n" $name $network.GlobalIPv6Address}}{{end}}' "$QBT_CONTAINER_NAME" 2>/dev/null || true)"
	[[ -n "$networks" ]] || return 1
	if [[ -n "$QBT_NETWORK_NAME" ]]; then
		ip="$(awk -F= -v target="$QBT_NETWORK_NAME" '$1 == target && $2 != "" {print $2; exit}' <<<"$networks")"
	fi
	[[ -n "$ip" ]] || ip="$(awk -F= '$2 != "" {print $2; exit}' <<<"$networks")"
	[[ -n "$ip" ]] || return 1
	printf '%s\n' "$ip"
}

read_cached_qbt_container_ipv6() {
	[[ -f "$QBT_CONTAINER_IP6_STATE_FILE" ]] || return 1
	cat "$QBT_CONTAINER_IP6_STATE_FILE" 2>/dev/null || true
}

read_cached_qbt_container_ip() {
	[[ -f "$QBT_CONTAINER_IP_STATE_FILE" ]] || return 1
	cat "$QBT_CONTAINER_IP_STATE_FILE" 2>/dev/null || true
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

for cmd in cat chmod ip mktemp rm wg-quick; do
	require_command "$cmd"
done

runtime_wg_config_path() {
	local target="${1:-}"

	[[ "$target" == "$WG_RUNTIME_DIR"/*.conf ]]
}

secure_runtime_wg_config() {
	local target="$1"

	if runtime_wg_config_path "$target" && [[ -f "$target" ]]; then
		chmod 700 "$WG_RUNTIME_DIR" 2>/dev/null || true
		chmod 600 "$target" 2>/dev/null || true
	fi
}

filter_wg_quick_stderr() {
	local target="$1"
	local line

	while IFS= read -r line; do
		case "$line" in
		"stat: cannot read table of mounted file systems: Permission denied")
			continue
			;;
		"/usr/bin/wg-quick: line 47: ((: ( &  & 0007) == 0: syntax error: operand expected (error token is \"&  & 0007) == 0\")")
			continue
			;;
		esac

		if runtime_wg_config_path "$target" && [[ "$line" == "Warning: \`$target' is world accessible" ]]; then
			continue
		fi

		printf '%s\n' "$line" >&2
	done
}

run_wg_quick() {
	local action="$1"
	local target="$2"
	local stderr_file=""
	local rc=0

	secure_runtime_wg_config "$target"
	stderr_file="$(mktemp)"

	if wg-quick "$action" "$target" 2>"$stderr_file"; then
		rc=0
	else
		rc=$?
	fi

	filter_wg_quick_stderr "$target" <"$stderr_file"
	rm -f "$stderr_file"

	return "$rc"
}

if [[ -z "$DOCKER_NETWORK_CIDR" && -f "$DOCKER_NETWORK_CIDR_STATE_FILE" ]]; then
	DOCKER_NETWORK_CIDR="$(cat "$DOCKER_NETWORK_CIDR_STATE_FILE" 2>/dev/null || true)"
fi

if [[ -f "$SERVER_SELECTION_FILE" ]]; then
	# shellcheck disable=SC1090
	source "$SERVER_SELECTION_FILE"
	WG_PROFILE="${WG_PROFILE:-${SELECTED_WG_PROFILE:-$WG_PROFILE}}"
	VPN_INTERFACE="${VPN_INTERFACE:-${SELECTED_VPN_INTERFACE:-$VPN_INTERFACE}}"
	WG_CONFIG="${SELECTED_CONFIG:-$WG_CONFIG}"
	FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"
fi

# Remove Docker policy routing before tearing down the interface so
# forwarded container traffic cannot fall back to stale routes. Shared
# Docker<->Docker and Docker<->LAN main-table rules are intentionally left in
# place because other Proton instances may still be active on the same bridge.
if ! proton_route_lock_acquire; then
	log "ERROR: Could not acquire the shared policy-route lock for $INSTANCE"
	exit 1
fi
QBT_CONTAINER_IP="$(resolve_qbt_container_ip || true)"
CACHED_QBT_CONTAINER_IP="$(read_cached_qbt_container_ip || true)"
for source_ip in "$QBT_CONTAINER_IP" "$CACHED_QBT_CONTAINER_IP"; do
	source_rule="$(normalize_ipv4_rule_source "$source_ip" || true)"
	[[ -n "$source_rule" ]] || continue
	ip rule del from "$source_rule" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
done

for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
	cidr="$(trim_field "$cidr")"
	[[ -n "$cidr" ]] || continue
	ip rule del to "$cidr" lookup main priority "$DOCKER_DEST_MAIN_RULE_PRIORITY" 2>/dev/null || true
done
ip rule del fwmark "$VPN_FWMARK" lookup "$VPN_TABLE" priority 100 2>/dev/null || true
ip rule del not fwmark "$VPN_FWMARK" lookup "$VPN_TABLE" priority 100 2>/dev/null || true
ip rule del table main suppress_prefixlength 0 priority 99 2>/dev/null || true
ip route flush table "$VPN_TABLE" 2>/dev/null || true
if ipv6_enabled; then
	QBT_CONTAINER_IPV6="$(resolve_qbt_container_ipv6 || true)"
	CACHED_QBT_CONTAINER_IPV6="$(read_cached_qbt_container_ipv6 || true)"
	for source_ip in "$QBT_CONTAINER_IPV6" "$CACHED_QBT_CONTAINER_IPV6"; do
		source_rule="$(normalize_ipv6_rule_source "$source_ip" || true)"
		[[ -n "$source_rule" ]] || continue
		ip -6 rule del from "$source_rule" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
	done
	for cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
		cidr="$(trim_field "$cidr")"
		[[ -n "$cidr" ]] || continue
		ip -6 rule del from "$cidr" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY" 2>/dev/null || true
	done
	ip -6 rule del oif "$VPN_INTERFACE" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
	ip -6 route flush table "$VPN_TABLE" 2>/dev/null || true
fi
if [[ -n "$DOCKER_NETWORK_CIDR" ]]; then
	detect_lan_cidr
	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		cidr="$(trim_field "$cidr")"
		[[ -n "$cidr" ]] || continue
		ip rule del from "$cidr" lookup 51820 priority "$DOCKER_VPN_RULE_PRIORITY" 2>/dev/null || true
		ip rule del from "$cidr" lookup "$VPN_TABLE" priority "$DOCKER_VPN_RULE_PRIORITY" 2>/dev/null || true
		ip rule del from "$cidr" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY" 2>/dev/null || true

		if command -v iptables >/dev/null 2>&1; then
			iptables -t raw -D PREROUTING -i "$VPN_INTERFACE" -d "$cidr" -j ACCEPT 2>/dev/null || true
		fi
	done
fi

if command -v iptables >/dev/null 2>&1; then
	iptables -t mangle -D FORWARD -o "$VPN_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -D FORWARD -i "$VPN_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi

rm -f "$DOCKER_NETWORK_CIDR_STATE_FILE"
rm -f "$QBT_CONTAINER_IP_STATE_FILE"
rm -f "$QBT_CONTAINER_IP6_STATE_FILE"
proton_route_lock_release

teardown_resolved_dns "$VPN_INTERFACE"

if [[ -f "$FILTERED_CONFIG_PATH" ]]; then
	run_wg_quick down "$FILTERED_CONFIG_PATH" || true
elif [[ -f "$WG_CONFIG" ]]; then
	run_wg_quick down "$WG_CONFIG" || true
else
	run_wg_quick down "$WG_PROFILE" || true
fi
