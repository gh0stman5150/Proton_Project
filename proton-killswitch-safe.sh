#!/usr/bin/env bash
set -euo pipefail

WG_PROFILE="${WG_PROFILE:-proton}"
VPN_IF="${VPN_IF:-${VPN_INTERFACE:-$WG_PROFILE}}"
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/${WG_PROFILE}.conf}"
WG_ENDPOINT_IP="${WG_ENDPOINT_IP:-}"
MANAGEMENT_TCP_PORTS="${MANAGEMENT_TCP_PORTS:-22,3389}"
MANAGEMENT_UDP_PORTS="${MANAGEMENT_UDP_PORTS:-3389}"
BYPASS_TCP_PORTS="${BYPASS_TCP_PORTS:-22,3389}"
BYPASS_UDP_PORTS="${BYPASS_UDP_PORTS:-3389}"
DOCKER_NETWORK_CIDR="${DOCKER_NETWORK_CIDR:-}"
INPUT_CHAIN="${INPUT_CHAIN:-PROTON_INPUT}"
OUTPUT_CHAIN="${OUTPUT_CHAIN:-PROTON_OUTPUT}"
NAT_CHAIN="${NAT_CHAIN:-PROTON_POSTROUTING}"
STATE_DIR="${STATE_DIR:-/run/proton}"
DOCKER_NETWORK_CIDR_STATE_FILE="${DOCKER_NETWORK_CIDR_STATE_FILE:-${STATE_DIR}/docker-network-cidr}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
SERVER_RESELECT_FILE="${SERVER_RESELECT_FILE:-${STATE_DIR}/reselect-server.flag}"
SERVER_POOL_ENABLED="${SERVER_POOL_ENABLED:-auto}"
SERVER_MANAGER_SCRIPT="${SERVER_MANAGER_SCRIPT:-/usr/local/bin/proton/proton-server-manager.sh}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"

log() {
	echo "$(date '+%F %T') | $*" | systemd-cat -t proton-killswitch
}

# Retry LAN_IF detection — on boot the default route may not be present yet.
if [[ -z "${LAN_IF:-}" ]]; then
	for _i in 1 2 3 4 5 6; do
		LAN_IF="$(ip route | awk '/default/ {print $5; exit}')"
		[[ -n "$LAN_IF" ]] && break
		log "Waiting for default route (attempt $_i/6)..."
		sleep 5
	done
fi
LAN_IF="${LAN_IF:-}"
LAN_CIDR="${LAN_CIDR:-$(ip -4 route show dev "$LAN_IF" | awk '$1 ~ /^[0-9]/ && $1 != "default" {print $1; exit}')}"
MANAGEMENT_ALLOWED_CIDRS="${MANAGEMENT_ALLOWED_CIDRS:-$LAN_CIDR}"

require_command() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		log "ERROR: Required command '$cmd' is not installed."
		exit 1
	fi
}

for cmd in awk cat chmod getent ip iptables mkdir systemd-cat tr; do
	require_command "$cmd"
done

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

if [[ -z "$DOCKER_NETWORK_CIDR" && -f "$DOCKER_NETWORK_CIDR_STATE_FILE" ]]; then
	DOCKER_NETWORK_CIDR="$(cat "$DOCKER_NETWORK_CIDR_STATE_FILE" 2>/dev/null || true)"
fi

server_pool_requested() {
	case "$SERVER_POOL_ENABLED" in
	1 | true | yes | on)
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
		return 0
	fi

	if [[ ! -x "$SERVER_MANAGER_SCRIPT" ]]; then
		log "ERROR: Server manager script is not executable: $SERVER_MANAGER_SCRIPT"
		exit 1
	fi

	if [[ -f "$SERVER_SELECTION_FILE" && ! -f "$SERVER_RESELECT_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$SERVER_SELECTION_FILE"
	else
		"$SERVER_MANAGER_SCRIPT" select >/dev/null
	fi

	if [[ -f "$SERVER_SELECTION_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$SERVER_SELECTION_FILE"
		WG_PROFILE="${SELECTED_WG_PROFILE:-$WG_PROFILE}"
		VPN_IF="${SELECTED_VPN_INTERFACE:-$VPN_IF}"
		WG_CONFIG="${SELECTED_CONFIG:-$WG_CONFIG}"
		WG_ENDPOINT_IP="${SELECTED_ENDPOINT_IP:-$WG_ENDPOINT_IP}"
	fi
}

require_value() {
	local name="$1"
	local value="$2"

	if [[ -z "$value" ]]; then
		log "ERROR: Missing required value for $name"
		exit 1
	fi
}

trim_field() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s\n' "$value"
}

for_each_csv() {
	local csv="$1"
	local callback="$2"
	local old_ifs item trimmed

	old_ifs="$IFS"
	IFS=','
	for item in $csv; do
		trimmed="$(trim_field "$item")"
		if [[ -n "$trimmed" ]]; then
			"$callback" "$trimmed"
		fi
	done
	IFS="$old_ifs"
}

allow_docker_input_for_cidr() {
	local cidr="$1"

	iptables -A "$INPUT_CHAIN" -s "$cidr" -j ACCEPT
}

allow_docker_output_for_cidr() {
	local cidr="$1"

	iptables -A "$OUTPUT_CHAIN" -d "$cidr" -j ACCEPT
}

allow_management_tcp_for_cidr() {
	local cidr="$1"
	local port

	while IFS= read -r port; do
		iptables -A "$INPUT_CHAIN" -i "$LAN_IF" -p tcp -s "$cidr" --dport "$port" -j ACCEPT
	done < <(printf '%s\n' "$MANAGEMENT_TCP_PORTS" | tr ',' '\n' | awk '{$1=$1; print}')
}

allow_management_udp_for_cidr() {
	local cidr="$1"
	local port

	while IFS= read -r port; do
		iptables -A "$INPUT_CHAIN" -i "$LAN_IF" -p udp -s "$cidr" --dport "$port" -j ACCEPT
	done < <(printf '%s\n' "$MANAGEMENT_UDP_PORTS" | tr ',' '\n' | awk '{$1=$1; print}')
}

get_endpoint_value() {
	awk -F '=' '/^[[:space:]]*Endpoint[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$WG_CONFIG"
}

get_endpoint_host() {
	local endpoint
	endpoint="$(get_endpoint_value)"
	endpoint="${endpoint%:*}"
	endpoint="${endpoint#[}"
	endpoint="${endpoint%]}"
	echo "$endpoint"
}

get_endpoint_port() {
	local endpoint
	endpoint="$(get_endpoint_value)"
	echo "${endpoint##*:}"
}

resolve_endpoint_ip() {
	local host="$1"

	if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "$host"
		return 0
	fi

	local ip
	ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1}') || ip=""
	if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "$ip"
		return 0
	fi

	return 1
}

load_selected_server

require_value "LAN_IF" "$LAN_IF"
require_value "LAN_CIDR" "$LAN_CIDR"
require_value "WG_CONFIG" "$WG_CONFIG"

if [[ ! -f "$WG_CONFIG" ]]; then
	log "ERROR: WireGuard config not found: $WG_CONFIG"
	exit 1
fi

ENDPOINT_HOST="$(get_endpoint_host)"
ENDPOINT_PORT="$(get_endpoint_port)"
ENDPOINT_IP="${WG_ENDPOINT_IP:-$(resolve_endpoint_ip "$ENDPOINT_HOST")}"

require_value "WireGuard endpoint host" "$ENDPOINT_HOST"
require_value "WireGuard endpoint port" "$ENDPOINT_PORT"
require_value "WireGuard endpoint IP" "$ENDPOINT_IP"

# IPv6 is intentionally omitted here because it is disabled in the WireGuard profile.
# This script only manages dedicated INPUT/OUTPUT chains so it does not wipe
# Docker-managed FORWARD/nat rules during startup.

ensure_chain() {
	local chain="$1"

	iptables -N "$chain" 2>/dev/null || true
	iptables -F "$chain"
}

ensure_jump_rule() {
	local parent="$1"
	local chain="$2"

	iptables -D "$parent" -j "$chain" 2>/dev/null || true
	iptables -I "$parent" 1 -j "$chain"
}

ensure_nat_chain() {
	iptables -t nat -N "$NAT_CHAIN" 2>/dev/null || true
	iptables -t nat -F "$NAT_CHAIN"
	iptables -t nat -D POSTROUTING -j "$NAT_CHAIN" 2>/dev/null || true
	iptables -t nat -I POSTROUTING 1 -j "$NAT_CHAIN"
}

ensure_chain "$INPUT_CHAIN"
ensure_chain "$OUTPUT_CHAIN"
ensure_nat_chain

ensure_jump_rule INPUT "$INPUT_CHAIN"
ensure_jump_rule OUTPUT "$OUTPUT_CHAIN"

iptables -A "$OUTPUT_CHAIN" -o lo -j ACCEPT
iptables -A "$INPUT_CHAIN" -i lo -j ACCEPT

iptables -A "$OUTPUT_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A "$INPUT_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

for_each_csv "$DOCKER_NETWORK_CIDR" allow_docker_input_for_cidr
for_each_csv "$DOCKER_NETWORK_CIDR" allow_docker_output_for_cidr
for_each_csv "$MANAGEMENT_ALLOWED_CIDRS" allow_management_tcp_for_cidr
for_each_csv "$MANAGEMENT_ALLOWED_CIDRS" allow_management_udp_for_cidr

iptables -A "$INPUT_CHAIN" -i "$LAN_IF" -s "$LAN_CIDR" -j ACCEPT

iptables -A "$OUTPUT_CHAIN" -o "$LAN_IF" -p udp --sport 68 --dport 67 -j ACCEPT
iptables -A "$INPUT_CHAIN" -i "$LAN_IF" -p udp --sport 67 --dport 68 -j ACCEPT

iptables -A "$OUTPUT_CHAIN" -o "$LAN_IF" -p udp -d "$ENDPOINT_IP" --dport "$ENDPOINT_PORT" -j ACCEPT
iptables -A "$INPUT_CHAIN" -i "$LAN_IF" -p udp -s "$ENDPOINT_IP" --sport "$ENDPOINT_PORT" -j ACCEPT

iptables -A "$OUTPUT_CHAIN" -o "$LAN_IF" -d "$LAN_CIDR" -j ACCEPT
iptables -A "$OUTPUT_CHAIN" -o "$VPN_IF" -j ACCEPT
iptables -A "$INPUT_CHAIN" -i "$VPN_IF" -j ACCEPT

# Bypass selected outbound ports — these go direct via ISP without VPN.
# SSH and RDP are bypassed by default so management access is never lost.
while IFS= read -r _port; do
	[[ -n "$_port" ]] || continue
	iptables -A "$OUTPUT_CHAIN" -o "$LAN_IF" -p tcp --dport "$_port" -j ACCEPT
done < <(printf '%s\n' "$BYPASS_TCP_PORTS" | tr ',' '\n' | awk '{$1=$1; print}')

iptables -A "$OUTPUT_CHAIN" -o "$LAN_IF" -p tcp --dport 53 -j ACCEPT

while IFS= read -r _port; do
	[[ -n "$_port" ]] || continue
	iptables -A "$OUTPUT_CHAIN" -o "$LAN_IF" -p udp --dport "$_port" -j ACCEPT
done < <(printf '%s\n' "$BYPASS_UDP_PORTS" | tr ',' '\n' | awk '{$1=$1; print}')

iptables -A "$OUTPUT_CHAIN" -o "$LAN_IF" -p udp --dport 53 -j ACCEPT

iptables -A "$NAT_CHAIN" -o "$VPN_IF" -j MASQUERADE

iptables -A "$OUTPUT_CHAIN" -j DROP
iptables -A "$INPUT_CHAIN" -j DROP

log "Kill switch chains applied on $LAN_IF with Proton endpoint ${ENDPOINT_IP}:${ENDPOINT_PORT}; management ports TCP[$MANAGEMENT_TCP_PORTS] UDP[$MANAGEMENT_UDP_PORTS] allowed from [$MANAGEMENT_ALLOWED_CIDRS]; bypass TCP[$BYPASS_TCP_PORTS] UDP[$BYPASS_UDP_PORTS] via ISP; postrouting masquerade enabled on $VPN_IF"
