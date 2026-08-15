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
NATPMP_GATEWAY="${NATPMP_GATEWAY:-10.2.0.1}"
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/${WG_PROFILE}.conf}"
WG_IPV6_ENABLED="${WG_IPV6_ENABLED:-off}"
# Proton drops the NAT-PMP mapping (and eventually the session) when a tunnel
# goes idle between port-forward polls. A PersistentKeepalive keeps the session
# warm so natpmpc stops timing out intermittently. Set to 0/empty to disable.
WG_PERSISTENT_KEEPALIVE="${WG_PERSISTENT_KEEPALIVE:-25}"
STATE_DIR="${STATE_DIR:-/run/proton}"
WG_RUNTIME_DIR="${WG_RUNTIME_DIR:-/etc/wireguard/proton-runtime}"
DOCKER_NETWORK_CIDR_STATE_FILE="${DOCKER_NETWORK_CIDR_STATE_FILE:-${STATE_DIR}/docker-network-cidr}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
SERVER_RESELECT_FILE="${SERVER_RESELECT_FILE:-${STATE_DIR}/reselect-server.flag}"
SERVER_POOL_ENABLED="${SERVER_POOL_ENABLED:-auto}"
SERVER_MANAGER_SCRIPT="${SERVER_MANAGER_SCRIPT:-/usr/local/bin/proton/proton-server-manager.sh}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"
KILLSWITCH_SCRIPT="${KILLSWITCH_SCRIPT:-/usr/local/bin/proton/proton-killswitch-dispatch.sh}"
VPN_FWMARK="${VPN_FWMARK:-0xca6c}"
VPN_TABLE="${VPN_TABLE:-51820}"
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
DOCKER_FALLBACK_VPN_ROUTING="${DOCKER_FALLBACK_VPN_ROUTING:-on}"
DOCKER_IPV6_FALLBACK_INSTANCE="${DOCKER_IPV6_FALLBACK_INSTANCE:-sonarr}"
DOCKER_DEST_MAIN_RULE_PRIORITY="${DOCKER_DEST_MAIN_RULE_PRIORITY:-98}"
MANAGE_RESOLVED_DNS="${MANAGE_RESOLVED_DNS:-auto}"
RESOLVED_DNS_ROUTE_DOMAIN="${RESOLVED_DNS_ROUTE_DOMAIN:-~.}"
PREVIOUS_WG_PROFILE="$WG_PROFILE"
PREVIOUS_WG_CONFIG=""
PREVIOUS_VPN_INTERFACE="$VPN_INTERFACE"
WG_CONFIG_TO_USE="$WG_CONFIG"
FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"
DNS_SERVERS_CSV=""

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

for cmd in awk cat chmod cut ip mkdir mktemp mv rm systemd-cat wg-quick; do
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

	if ((created)) && [[ -n "$mode" ]]; then
		chmod "$mode" "$dir"
	fi
}

ensure_directory "$STATE_DIR" 700
ensure_directory "$WG_RUNTIME_DIR" 700

runtime_wg_config_path() {
	local target="${1:-}"

	[[ "$target" == "$WG_RUNTIME_DIR"/*.conf ]]
}

secure_runtime_wg_config() {
	local target="${1:-$WG_CONFIG_TO_USE}"

	chmod 700 "$WG_RUNTIME_DIR" 2>/dev/null || true

	if runtime_wg_config_path "$target" && [[ -f "$target" ]]; then
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

	if runtime_wg_config_path "$target"; then
		secure_runtime_wg_config "$target"
	fi

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

load_selected_server() {
	# The local WireGuard interface name and runtime config path are keyed on
	# the INSTANCE (e.g. pv<inst>), never on the selected server. This keeps
	# each instance's tunnel independent even when two instances happen to pick
	# the same Proton server. Server selection only chooses which pool config
	# supplies the [Peer] endpoint/keys; the per-instance Address subnet (and
	# therefore the NAT-PMP forwarded port) stays unique.
	PREVIOUS_WG_PROFILE="$WG_PROFILE"
	PREVIOUS_VPN_INTERFACE="$VPN_INTERFACE"
	PREVIOUS_WG_CONFIG="$FILTERED_CONFIG_PATH"

	if ! server_pool_requested; then
		return 0
	fi

	if [[ ! -x "$SERVER_MANAGER_SCRIPT" ]]; then
		log "ERROR: Server manager script is not executable: $SERVER_MANAGER_SCRIPT"
		exit 1
	fi

	if [[ ! -f "$SERVER_SELECTION_FILE" || -f "$SERVER_RESELECT_FILE" ]]; then
		# Run the server manager with the instance STATE_DIR so selection is per-instance.
		# Prevent the server manager from sourcing the global common env which would
		# override STATE_DIR by setting PROTON_COMMON_ENV_FILE=/dev/null.
		PROTON_COMMON_ENV_FILE=/dev/null STATE_DIR="$STATE_DIR" "$SERVER_MANAGER_SCRIPT" select >/dev/null
	fi

	if [[ -f "$SERVER_SELECTION_FILE" ]]; then
		# shellcheck disable=SC1090
		source "$SERVER_SELECTION_FILE"
		# Adopt only the source server config (peer/keys). Keep WG_PROFILE and
		# VPN_INTERFACE as the per-instance values from proton.env so the local
		# interface name and runtime config path never collide across instances.
		WG_CONFIG="${SELECTED_CONFIG:-$WG_CONFIG}"
		FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"
	fi
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

trim_field() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s\n' "$value"
}

is_ipv4_address() {
	local value="$1"
	local octet
	local -a octets=()

	[[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
	IFS='.' read -r -a octets <<<"$value"
	[[ "${#octets[@]}" -eq 4 ]] || return 1

	for octet in "${octets[@]}"; do
		[[ "$octet" =~ ^[0-9]+$ ]] || return 1
		((10#$octet <= 255)) || return 1
	done
}

normalize_ipv4_rule_source() {
	local value="$1"
	local addr=""
	local prefix=""

	value="$(trim_field "$value")"
	[[ -n "$value" ]] || return 1
	if [[ "$value" == */* ]]; then
		addr="${value%%/*}"
		prefix="${value#*/}"
		is_ipv4_address "$addr" || return 1
		[[ "$prefix" =~ ^[0-9]+$ ]] || return 1
		((prefix >= 0 && prefix <= 32)) || return 1
		printf '%s/%s\n' "$addr" "$prefix"
	else
		is_ipv4_address "$value" || return 1
		printf '%s/32\n' "$value"
	fi
}

normalize_ipv6_rule_source() {
	local value="$1"

	value="$(trim_field "$value")"
	[[ "$value" == *:* ]] || return 1
	printf '%s/128\n' "${value%%/*}"
}

docker_fallback_vpn_routing_enabled() {
	case "$DOCKER_FALLBACK_VPN_ROUTING" in
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
	if [[ -z "$ip" ]]; then
		ip="$(awk -F= '$2 != "" {print $2; exit}' <<<"$networks")"
	fi

	[[ -n "$ip" ]] || return 1
	printf '%s\n' "$ip"
}

read_cached_qbt_container_ipv6() {
	[[ -f "$QBT_CONTAINER_IP6_STATE_FILE" ]] || return 1
	cat "$QBT_CONTAINER_IP6_STATE_FILE" 2>/dev/null || true
}

persist_qbt_container_ipv6() {
	local value="${1:-}"

	if [[ -n "$value" ]]; then
		umask 077
		printf '%s' "$value" >"$QBT_CONTAINER_IP6_STATE_FILE"
	else
		rm -f "$QBT_CONTAINER_IP6_STATE_FILE" 2>/dev/null || true
	fi
}

docker_ipv6_fallback_enabled() {
	ipv6_enabled && docker_fallback_vpn_routing_enabled && [[ "$INSTANCE" == "$DOCKER_IPV6_FALLBACK_INSTANCE" ]]
}

read_cached_qbt_container_ip() {
	[[ -f "$QBT_CONTAINER_IP_STATE_FILE" ]] || return 1
	cat "$QBT_CONTAINER_IP_STATE_FILE" 2>/dev/null || true
}

persist_qbt_container_ip() {
	local value="${1:-}"

	if [[ -n "$value" ]]; then
		umask 077
		printf '%s' "$value" >"$QBT_CONTAINER_IP_STATE_FILE"
	else
		rm -f "$QBT_CONTAINER_IP_STATE_FILE" 2>/dev/null || true
	fi
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

ensure_docker_raw_return_rule() {
	local cidr

	if [[ -z "$DOCKER_NETWORK_CIDR" ]]; then
		return 0
	fi

	if ! command -v iptables >/dev/null 2>&1; then
		return 0
	fi

	# Docker installs raw-table anti-spoof drops for published container IPs.
	# VPN replies to container-originated traffic can re-enter on the tunnel
	# interface already destined for the container IP, so allow that path
	# before Docker's "! -i br-... -j DROP" rules fire.
	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		cidr="$(trim_field "$cidr")"
		[[ -n "$cidr" ]] || continue
		iptables -t raw -D PREROUTING -i "$VPN_INTERFACE" -d "$cidr" -j ACCEPT 2>/dev/null || true
		iptables -t raw -I PREROUTING 1 -i "$VPN_INTERFACE" -d "$cidr" -j ACCEPT
		log "Allowed VPN return traffic from $VPN_INTERFACE to Docker subnet $cidr in raw PREROUTING"
	done
}

ensure_vpn_tcp_mss_clamp_rules() {
	if ! command -v iptables >/dev/null 2>&1; then
		return 0
	fi

	# Forwarded TCP sessions over WireGuard can blackhole large segments when
	# Docker bridges still use a 1500-byte MTU. Clamp MSS in both directions
	# across the VPN interface so app traffic works even when ICMP ping already
	# looks healthy.
	iptables -t mangle -D FORWARD -o "$VPN_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -I FORWARD 1 -o "$VPN_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
	iptables -t mangle -D FORWARD -i "$VPN_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
	iptables -t mangle -I FORWARD 1 -i "$VPN_INTERFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
	log "Clamped TCP MSS for forwarded traffic crossing $VPN_INTERFACE"
}

uses_nftables_backend() {
	case "$KILLSWITCH_BACKEND" in
	nft | nftables)
		return 0
		;;
	iptables)
		return 1
		;;
	auto)
		command -v nft >/dev/null 2>&1
		;;
	*)
		return 1
		;;
	esac
}

config_dns_servers() {
	awk -F '=' '
        /^[[:space:]]*DNS[[:space:]]*=/ {
            value = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            if (value != "") {
                out = out == "" ? value : out ", " value
            }
        }
        END { print out }
    ' "$1"
}

teardown_resolved_dns() {
	local ifname="$1"

	resolved_dns_enabled || return 0
	[[ -n "$ifname" ]] || return 0

	resolvectl revert "$ifname" >/dev/null 2>&1 || true
	resolvectl flush-caches >/dev/null 2>&1 || true
}

configure_resolved_dns() {
	local ifname="$1"
	local dns_csv="$2"
	local old_ifs item trimmed
	local dns_servers=()

	resolved_dns_enabled || return 0
	[[ -n "$ifname" ]] || return 0

	if [[ -z "$dns_csv" ]]; then
		log "No DNS servers were defined in $WG_CONFIG_TO_USE; skipping systemd-resolved configuration"
		return 0
	fi

	old_ifs="$IFS"
	IFS=','
	for item in $dns_csv; do
		trimmed="$(trim_field "$item")"
		[[ -n "$trimmed" ]] || continue
		dns_servers+=("$trimmed")
	done
	IFS="$old_ifs"

	if [[ "${#dns_servers[@]}" -eq 0 ]]; then
		log "No usable DNS servers were parsed from $WG_CONFIG_TO_USE; skipping systemd-resolved configuration"
		return 0
	fi

	resolvectl dns "$ifname" "${dns_servers[@]}"
	if [[ -n "$RESOLVED_DNS_ROUTE_DOMAIN" ]]; then
		resolvectl domain "$ifname" "$RESOLVED_DNS_ROUTE_DOMAIN"
	fi
	resolvectl default-route "$ifname" yes
	resolvectl flush-caches >/dev/null 2>&1 || true
	log "Configured systemd-resolved DNS on $ifname: $dns_csv"
}

prepare_wg_config() {
	local source_config="$1"
	local tmp_config=""
	local keep_ipv6=0

	# NOTE: The WireGuard [Interface] section must contain "Table = off" so
	# wg-quick does not install its own fwmark-based routing rules, which
	# conflict with the policy routing this script manages via inject_routes.

	if ipv6_enabled; then
		keep_ipv6=1
	fi

	tmp_config="$(mktemp "${WG_RUNTIME_DIR}/${WG_PROFILE}.XXXXXX.conf")"

	awk -v keep_ipv6="$keep_ipv6" -v keepalive="$WG_PERSISTENT_KEEPALIVE" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }

        function filter_ipv4_csv(csv,    n, i, item, out) {
            n = split(csv, parts, /,/)
            out = ""
            for (i = 1; i <= n; i++) {
                item = trim(parts[i])
                if (item ~ /:/) {
                    continue
                }
                if (item != "") {
                    out = out == "" ? item : out ", " item
                }
            }
            return out
        }

        function flush_interface_defaults() {
            if (in_interface && !table_written) {
                print "Table = off"
            }
        }

        function flush_peer_defaults() {
            if (in_peer && !keepalive_written && keepalive != "" && keepalive != "0") {
                print "PersistentKeepalive = " keepalive
            }
        }

        /^[[:space:]]*\[/ {
            flush_interface_defaults()
            flush_peer_defaults()
            in_interface = ($0 ~ /^[[:space:]]*\[Interface\][[:space:]]*$/)
            in_peer = ($0 ~ /^[[:space:]]*\[Peer\][[:space:]]*$/)
            table_written = in_interface ? 0 : 1
            if (in_peer) {
                keepalive_written = 0
            }
            print
            next
        }

        in_peer && /^[[:space:]]*PersistentKeepalive[[:space:]]*=/ {
            keepalive_written = 1
            print
            next
        }

        in_interface && /^[[:space:]]*Table[[:space:]]*=/ {
            print "Table = off"
            table_written = 1
            next
        }

        !keep_ipv6 && /^[[:space:]]*Address[[:space:]]*=/ {
            value = substr($0, index($0, "=") + 1)
            value = filter_ipv4_csv(value)
            if (value != "") {
                print "Address = " value
            }
            next
        }

        !keep_ipv6 && /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
            value = substr($0, index($0, "=") + 1)
            value = filter_ipv4_csv(value)
            if (value != "") {
                print "AllowedIPs = " value
            }
            next
        }

        !keep_ipv6 && /^[[:space:]]*DNS[[:space:]]*=/ {
            value = substr($0, index($0, "=") + 1)
            value = filter_ipv4_csv(value)
            if (value != "") {
                print "DNS = " value
            }
            next
        }

        { print }

        END {
            flush_interface_defaults()
            flush_peer_defaults()
        }
    ' "$source_config" >"$tmp_config"

	chmod 600 "$tmp_config"
	mv -f "$tmp_config" "$FILTERED_CONFIG_PATH"
	WG_CONFIG_TO_USE="$FILTERED_CONFIG_PATH"
}

# Rewrite the [Interface] Address and DNS in the runtime config to this
# instance's assigned subnet. Proton ties each NAT-PMP forwarded port to the
# client tunnel address, so giving every instance a distinct address
# (10.2.0.2, 10.3.0.2, ...) yields a distinct forwarded port per instance. The
# shared pool configs are left untouched (they keep 10.2.0.2 for linting); only
# the per-instance runtime copy is rewritten.
apply_tunnel_addressing() {
	[[ -n "${WG_TUNNEL_ADDRESS:-}" ]] || return 0

	local tmp_config keep_ipv6=0
	if ipv6_enabled; then
		keep_ipv6=1
	fi
	tmp_config="$(mktemp "${WG_RUNTIME_DIR}/${WG_PROFILE}.XXXXXX.conf")"

	awk -v addr="$WG_TUNNEL_ADDRESS" -v dns="${WG_TUNNEL_DNS:-}" -v keep_ipv6="$keep_ipv6" '
		function trim(s) {
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
			return s
		}

		function ipv6_csv(csv,    n, i, item, out) {
			n = split(csv, values, /,/)
			for (i = 1; i <= n; i++) {
				item = trim(values[i])
				if (item ~ /:/) {
					out = out == "" ? item : out ", " item
				}
			}
			return out
		}

        /^[[:space:]]*\[/ { section = $0 }

        section ~ /\[Interface\]/ && /^[[:space:]]*Address[[:space:]]*=/ {
			value = substr($0, index($0, "=") + 1)
			preserved = keep_ipv6 ? ipv6_csv(value) : ""
			print "Address = " addr (preserved != "" ? ", " preserved : "")
            next
        }

        section ~ /\[Interface\]/ && /^[[:space:]]*DNS[[:space:]]*=/ {
            if (dns != "") {
				value = substr($0, index($0, "=") + 1)
				preserved = keep_ipv6 ? ipv6_csv(value) : ""
				print "DNS = " dns (preserved != "" ? ", " preserved : "")
            }
            next
        }

        { print }
    ' "$WG_CONFIG_TO_USE" >"$tmp_config"

	chmod 600 "$tmp_config"
	mv -f "$tmp_config" "$WG_CONFIG_TO_USE"
	log "Applied per-instance tunnel addressing: Address=${WG_TUNNEL_ADDRESS} DNS=${WG_TUNNEL_DNS:-unset} (NAT-PMP gateway ${NATPMP_GATEWAY})"
}

validate_runtime_ipv6() {
	ipv6_enabled || return 0

	if ! awk -F= '
		/^[[:space:]]*Address[[:space:]]*=/ && $2 ~ /:/ { address = 1 }
		/^[[:space:]]*AllowedIPs[[:space:]]*=/ && $2 ~ /(^|,[[:space:]]*)::\/0([[:space:]]*,|[[:space:]]*$)/ { allowed = 1 }
		END { exit !(address && allowed) }
	' "$WG_CONFIG_TO_USE"; then
		log "ERROR: IPv6 mode requires a Proton-assigned IPv6 interface address and AllowedIPs ::/0 in $WG_CONFIG_TO_USE"
		exit 1
	fi
}

persist_docker_network_cidr() {
	if [[ -n "$DOCKER_NETWORK_CIDR" ]]; then
		umask 077
		printf '%s' "$DOCKER_NETWORK_CIDR" >"$DOCKER_NETWORK_CIDR_STATE_FILE"
	else
		rm -f "$DOCKER_NETWORK_CIDR_STATE_FILE"
	fi
}

resolve_docker_network_cidr() {
	local candidate=""
	local subnet=""

	if [[ -z "$DOCKER_NETWORK_CIDR" ]] && command -v docker >/dev/null 2>&1; then
		candidate=$(docker network ls --format '{{.Name}}' | grep -i starr | head -n1 || true)
		if [[ -n "$candidate" ]]; then
			subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$candidate" 2>/dev/null || true)
			if [[ -n "$subnet" ]]; then
				DOCKER_NETWORK_CIDR="$subnet"
				log "Auto-detected Docker network '$candidate' -> $DOCKER_NETWORK_CIDR"
			fi
		fi
	fi

	if [[ -z "$DOCKER_NETWORK_CIDR" && -f "$DOCKER_NETWORK_CIDR_STATE_FILE" ]]; then
		DOCKER_NETWORK_CIDR="$(cat "$DOCKER_NETWORK_CIDR_STATE_FILE" 2>/dev/null || true)"
	fi

	persist_docker_network_cidr
	export DOCKER_NETWORK_CIDR
}

load_selected_server
prepare_wg_config "$WG_CONFIG"
apply_tunnel_addressing
validate_runtime_ipv6
secure_runtime_wg_config "$WG_CONFIG_TO_USE"
DNS_SERVERS_CSV="$(config_dns_servers "$WG_CONFIG_TO_USE")"
resolve_docker_network_cidr

log "Bringing up WireGuard profile $WG_PROFILE..."

teardown_resolved_dns "$PREVIOUS_VPN_INTERFACE"

if [[ -n "$PREVIOUS_WG_CONFIG" && -f "$PREVIOUS_WG_CONFIG" ]]; then
	wg-quick down "$PREVIOUS_WG_CONFIG" 2>/dev/null || true
else
	wg-quick down "$PREVIOUS_WG_PROFILE" 2>/dev/null || true
fi

if [[ -x "$KILLSWITCH_SCRIPT" ]]; then
	"$KILLSWITCH_SCRIPT"
fi

run_wg_quick up "$WG_CONFIG_TO_USE"

if uses_nftables_backend && [[ -x "$KILLSWITCH_SCRIPT" ]]; then
	# The initial pre-up apply prevents leaks during interface bring-up. Re-run
	# after the interface exists so nft postrouting masquerade is guaranteed.
	"$KILLSWITCH_SCRIPT"
fi

configure_resolved_dns "$VPN_INTERFACE" "$DNS_SERVERS_CSV"

inject_routes() {
	ip route del "$NATPMP_GATEWAY" 2>/dev/null || true

	# Clean stale rules first (avoid duplicates and remove old host-wide rules).
	for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
		cidr="$(trim_field "$cidr")"
		[[ -n "$cidr" ]] || continue
		ip rule del to "$cidr" lookup main priority "$DOCKER_DEST_MAIN_RULE_PRIORITY" 2>/dev/null || true
	done
	ip rule del fwmark "$VPN_FWMARK" lookup "$VPN_TABLE" priority 100 2>/dev/null || true
	ip rule del not fwmark "$VPN_FWMARK" lookup "$VPN_TABLE" priority 100 2>/dev/null || true
	ip rule del table main suppress_prefixlength 0 priority 99 2>/dev/null || true
	ip route replace default dev "$VPN_INTERFACE" table "$VPN_TABLE"
	if ipv6_enabled; then
		ip -6 route replace default dev "$VPN_INTERFACE" table "$VPN_TABLE"
		ip -6 rule del oif "$VPN_INTERFACE" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
		ip -6 rule add oif "$VPN_INTERFACE" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY"
	fi
	# NATPMP gateway must be reachable inside the tunnel table too.
	ip route replace "$NATPMP_GATEWAY" dev "$VPN_INTERFACE" table "$VPN_TABLE"
	# Keep the direct host route in the main table for natpmpc.
	ip route replace "$NATPMP_GATEWAY" dev "$VPN_INTERFACE" 2>/dev/null || true

	# Keep Docker<->Docker and Docker<->LAN traffic on the main table, while
	# qBittorrent container traffic is forced into this instance's VPN table.
	# A lower-priority Docker subnet fallback keeps non-qBittorrent apps on a
	# Proton tunnel without stealing qBittorrent replies from their owner tunnel.
	if [[ -n "$DOCKER_NETWORK_CIDR" ]]; then
		local qbt_container_ip=""
		local qbt_rule_source=""
		local cached_qbt_container_ip=""
		local cached_qbt_rule_source=""

		qbt_container_ip="$(resolve_qbt_container_ip || true)"
		cached_qbt_container_ip="$(read_cached_qbt_container_ip || true)"

		if [[ -n "$cached_qbt_container_ip" ]]; then
			cached_qbt_rule_source="$(normalize_ipv4_rule_source "$cached_qbt_container_ip" || true)"
			if [[ -n "$cached_qbt_rule_source" ]]; then
				ip rule del from "$cached_qbt_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
			fi
		fi

		if [[ -n "$qbt_container_ip" ]]; then
			qbt_rule_source="$(normalize_ipv4_rule_source "$qbt_container_ip" || true)"
			if [[ -n "$qbt_rule_source" ]]; then
				ip rule del from "$qbt_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
			fi
		fi

		detect_lan_cidr
		for cidr in ${DOCKER_NETWORK_CIDR//,/ }; do
			cidr="$(trim_field "$cidr")"
			[[ -n "$cidr" ]] || continue
			proton_replace_ip_rule 4 from "$cidr" to "$cidr" lookup main priority "$DOCKER_LOCAL_RULE_PRIORITY"

			if [[ -n "$LAN_CIDR" ]]; then
				proton_replace_ip_rule 4 from "$cidr" to "$LAN_CIDR" lookup main priority "$DOCKER_LAN_RULE_PRIORITY"
			fi

			# Remove the legacy singleton Docker->VPN rule. With multiple
			# instance tables it has a lower priority number than the qBittorrent
			# /32 rules, so leaving it in place would still collapse every
			# container onto table 51820.
			ip rule del from "$cidr" lookup 51820 priority "$DOCKER_VPN_RULE_PRIORITY" 2>/dev/null || true
			ip rule del from "$cidr" lookup "$VPN_TABLE" priority "$DOCKER_VPN_RULE_PRIORITY" 2>/dev/null || true
			ip rule del from "$cidr" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY" 2>/dev/null || true
			if docker_fallback_vpn_routing_enabled; then
				ip rule add from "$cidr" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY" 2>/dev/null || true
			fi
		done

		if [[ -n "$qbt_rule_source" ]]; then
			ip rule add from "$qbt_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY"
			persist_qbt_container_ip "$qbt_container_ip"
			log "qBittorrent policy routing: source $qbt_rule_source -> table $VPN_TABLE via $VPN_INTERFACE"
		else
			persist_qbt_container_ip ""
			if [[ -n "$QBT_CONTAINER_NAME" ]]; then
				log "WARNING: Could not resolve an IPv4 address for $QBT_CONTAINER_NAME; qBittorrent will use Docker fallback routing until the watcher reconciles it"
			fi
		fi

		ensure_docker_raw_return_rule
		if docker_fallback_vpn_routing_enabled; then
			log "Docker fallback policy routing: source $DOCKER_NETWORK_CIDR -> table $VPN_TABLE via $VPN_INTERFACE at priority $DOCKER_FALLBACK_VPN_RULE_PRIORITY while LAN traffic stays on main"
		else
			log "Docker fallback policy routing disabled; qBittorrent-specific rules remain active"
		fi
	else
		log "VPN table $VPN_TABLE prepared on $VPN_INTERFACE without Docker source rules"
	fi

	if ipv6_enabled && [[ -n "$DOCKER_NETWORK_CIDR6" ]]; then
		local qbt_container_ipv6=""
		local qbt_ipv6_rule_source=""
		local cached_qbt_container_ipv6=""
		local cached_qbt_ipv6_rule_source=""

		qbt_container_ipv6="$(resolve_qbt_container_ipv6 || true)"
		cached_qbt_container_ipv6="$(read_cached_qbt_container_ipv6 || true)"
		qbt_ipv6_rule_source="$(normalize_ipv6_rule_source "$qbt_container_ipv6" || true)"
		cached_qbt_ipv6_rule_source="$(normalize_ipv6_rule_source "$cached_qbt_container_ipv6" || true)"

		if [[ -n "$cached_qbt_ipv6_rule_source" ]]; then
			ip -6 rule del from "$cached_qbt_ipv6_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
		fi
		if [[ -n "$qbt_ipv6_rule_source" ]]; then
			ip -6 rule del from "$qbt_ipv6_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY" 2>/dev/null || true
		fi

		for cidr in ${DOCKER_NETWORK_CIDR6//,/ }; do
			cidr="$(trim_field "$cidr")"
			[[ -n "$cidr" ]] || continue
			proton_replace_ip_rule 6 from "$cidr" to "$cidr" lookup main priority "$DOCKER_LOCAL_RULE_PRIORITY"
			ip -6 rule del from "$cidr" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY" 2>/dev/null || true
			if docker_ipv6_fallback_enabled; then
				ip -6 rule add from "$cidr" lookup "$VPN_TABLE" priority "$DOCKER_FALLBACK_VPN_RULE_PRIORITY"
			fi
		done

		if [[ -n "$qbt_ipv6_rule_source" ]]; then
			ip -6 rule add from "$qbt_ipv6_rule_source" lookup "$VPN_TABLE" priority "$QBT_VPN_RULE_PRIORITY"
			persist_qbt_container_ipv6 "$qbt_container_ipv6"
			log "qBittorrent IPv6 policy routing: source $qbt_ipv6_rule_source -> table $VPN_TABLE via $VPN_INTERFACE"
		else
			persist_qbt_container_ipv6 ""
			log "WARNING: Could not resolve an IPv6 address for $QBT_CONTAINER_NAME; IPv6 remains unavailable until the watcher reconciles it"
		fi

		if docker_ipv6_fallback_enabled; then
			log "Docker IPv6 fallback owner: $INSTANCE routes $DOCKER_NETWORK_CIDR6 through table $VPN_TABLE via $VPN_INTERFACE"
		fi
	fi

	ensure_vpn_tcp_mss_clamp_rules
}

if ! proton_route_lock_acquire; then
	log "ERROR: Could not acquire the shared policy-route lock for $INSTANCE"
	exit 1
fi
inject_routes
proton_route_lock_release

# Wait for an IPv4 address on the VPN interface instead of a fixed sleep.
# Configurable timeout (seconds).
WG_UP_WAIT_SECONDS="${WG_UP_WAIT_SECONDS:-30}"

log "Waiting up to ${WG_UP_WAIT_SECONDS}s for an IPv4 address on $VPN_INTERFACE"
IP=""
for _i in $(seq 1 "$WG_UP_WAIT_SECONDS"); do
	IP="$(ip -4 addr show "$VPN_INTERFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 || true)"
	if [[ -n "$IP" ]]; then
		break
	fi
	sleep 1
done

if [[ -z "$IP" ]]; then
	log "ERROR: $VPN_INTERFACE came up without an IPv4 address"
	exit 1
fi

log "WireGuard up on $VPN_INTERFACE with IP: $IP"
