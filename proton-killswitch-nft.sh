#!/usr/bin/env bash
set -euo pipefail

WG_PROFILE="${WG_PROFILE:-proton}"
VPN_IF="${VPN_IF:-${VPN_INTERFACE:-$WG_PROFILE}}"
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/${WG_PROFILE}.conf}"
WG_ENDPOINT_IP="${WG_ENDPOINT_IP:-}"
VPN_FWMARK="${VPN_FWMARK:-0xca6c}"
# Convert fwmark to decimal for use in nft (nft may prefer decimal marks).
# Allow VPN_FWMARK to be provided as hex (0x...) or decimal.
VPN_FWMARK_DEC=$((VPN_FWMARK))
BYPASS_TCP_PORTS="${BYPASS_TCP_PORTS:-22,3389}"
BYPASS_UDP_PORTS="${BYPASS_UDP_PORTS:-3389}"
LAN_IF="${LAN_IF:-$(ip route | awk '/default/ {print $5; exit}')}"
LAN_CIDR="${LAN_CIDR:-$(ip -4 route show dev "$LAN_IF" | awk '$1 ~ /^[0-9]/ && $1 != "default" {print $1; exit}')}"
MANAGEMENT_ALLOWED_CIDRS="${MANAGEMENT_ALLOWED_CIDRS:-$LAN_CIDR}"
MANAGEMENT_TCP_PORTS="${MANAGEMENT_TCP_PORTS:-22,3389}"
MANAGEMENT_UDP_PORTS="${MANAGEMENT_UDP_PORTS:-3389}"
STATE_DIR="${STATE_DIR:-/run/proton}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
SERVER_RESELECT_FILE="${SERVER_RESELECT_FILE:-${STATE_DIR}/reselect-server.flag}"
SERVER_POOL_ENABLED="${SERVER_POOL_ENABLED:-auto}"
SERVER_MANAGER_SCRIPT="${SERVER_MANAGER_SCRIPT:-/usr/local/bin/proton/proton-server-manager.sh}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"
DOCKER_NETWORK_CIDR="${DOCKER_NETWORK_CIDR:-}"

log() {
    echo "$(date '+%F %T') | $*" | systemd-cat -t proton-killswitch
}

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: Required command '$cmd' is not installed."
        exit 1
    fi
}

for cmd in awk chmod getent ip mkdir nft systemd-cat; do
    require_command "$cmd"
done

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

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

csv_to_nft_set() {
    local csv="$1"
    local part trimmed result=""

    # Split on commas without mutating IFS (avoid side-effects). Using
    # parameter expansion to replace commas with spaces for safe iteration.
    for part in ${csv//,/ }; do
        trimmed="$(trim_field "$part")"
        [[ -n "$trimmed" ]] || continue
        if [[ -n "$result" ]]; then
            result="${result}, ${trimmed}"
        else
            result="$trimmed"
        fi
    done

    printf '%s\n' "$result"
}

bypass_output_rules() {
    local tcp_ports udp_ports

    tcp_ports="$(csv_to_nft_set "$BYPASS_TCP_PORTS")"
    udp_ports="$(csv_to_nft_set "$BYPASS_UDP_PORTS")"

    if [[ -n "$tcp_ports" ]]; then
        printf '        tcp dport { %s } return\n' "$tcp_ports"
    fi

    if [[ -n "$udp_ports" ]]; then
        printf '        udp dport { %s } return\n' "$udp_ports"
    fi
}

bypass_output_accept_rules() {
    local tcp_ports udp_ports

    tcp_ports="$(csv_to_nft_set "$BYPASS_TCP_PORTS")"
    udp_ports="$(csv_to_nft_set "$BYPASS_UDP_PORTS")"

    if [[ -n "$tcp_ports" ]]; then
        printf '        oifname "%s" tcp dport { %s } accept\n' "$LAN_IF" "$tcp_ports"
    fi

    if [[ -n "$udp_ports" ]]; then
        printf '        oifname "%s" udp dport { %s } accept\n' "$LAN_IF" "$udp_ports"
    fi
}

management_input_rules() {
    local cidr port trimmed

    # Iterate over comma-separated CIDRs and ports without mutating IFS.
    for cidr in ${MANAGEMENT_ALLOWED_CIDRS//,/ }; do
        cidr="$(trim_field "$cidr")"
        [[ -n "$cidr" ]] || continue

        for port in ${MANAGEMENT_TCP_PORTS//,/ }; do
            trimmed="$(trim_field "$port")"
            [[ -n "$trimmed" ]] || continue
            printf '        iifname "%s" ip saddr %s tcp dport %s accept\n' "$LAN_IF" "$cidr" "$trimmed"
        done

        for port in ${MANAGEMENT_UDP_PORTS//,/ }; do
            trimmed="$(trim_field "$port")"
            [[ -n "$trimmed" ]] || continue
            printf '        iifname "%s" ip saddr %s udp dport %s accept\n' "$LAN_IF" "$cidr" "$trimmed"
        done
    done
}

prerouting_mark_rules() {
    local part trimmed

    for part in ${DOCKER_NETWORK_CIDR//,/ }; do
        trimmed="$(trim_field "$part")"
        [[ -n "$trimmed" ]] || continue
        printf '        ip saddr %s meta mark set %s\n' "$trimmed" "$VPN_FWMARK_DEC"
    done
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

nft delete table inet proton 2>/dev/null || true

nft -f - <<EOF
table inet proton {
    chain prerouting_mangle {
        type filter hook prerouting priority -150; policy accept;
$(prerouting_mark_rules)
    }
    chain output_mangle {
        type route hook output priority -150; policy accept;
        ip daddr ${ENDPOINT_IP} udp dport ${ENDPOINT_PORT} return
$(bypass_output_rules)
        meta mark set ${VPN_FWMARK_DEC}
    }

    chain input {
        type filter hook input priority 0; policy accept;
        iifname "lo" accept
        ct state established,related accept
$(management_input_rules)
        iifname "$LAN_IF" ip saddr ${LAN_CIDR} accept
        iifname "$LAN_IF" udp sport 67 udp dport 68 accept
        iifname "$LAN_IF" ip saddr ${ENDPOINT_IP} udp sport ${ENDPOINT_PORT} accept
        iifname "$VPN_IF" accept
        counter drop
    }

    chain output {
        type filter hook output priority 0; policy accept;
        oifname "lo" accept
        ct state established,related accept
$(bypass_output_accept_rules)
        oifname "$LAN_IF" udp sport 68 udp dport 67 accept
        oifname "$LAN_IF" ip daddr ${ENDPOINT_IP} udp dport ${ENDPOINT_PORT} accept
        oifname "$VPN_IF" accept
        counter drop
    }
    chain forward {
        type filter hook forward priority 0; policy accept;
        ct state established,related accept
        # Allow forwarding that goes out the vpn interface
        oifname "$VPN_IF" accept
        # Allow LAN <-> LAN forwarding
        iifname "$LAN_IF" oifname "$LAN_IF" accept
        counter drop
    }
}
EOF

log "nftables kill switch applied on $LAN_IF with Proton endpoint ${ENDPOINT_IP}:${ENDPOINT_PORT}; management ports TCP[$MANAGEMENT_TCP_PORTS] UDP[$MANAGEMENT_UDP_PORTS] allowed from [$MANAGEMENT_ALLOWED_CIDRS]; VPN fwmark $VPN_FWMARK (bypass TCP[$BYPASS_TCP_PORTS] UDP[$BYPASS_UDP_PORTS])"
