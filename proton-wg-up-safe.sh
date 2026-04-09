#!/usr/bin/env bash
set -euo pipefail

LOG_TAG="${LOG_TAG:-proton-wg}"
WG_PROFILE="${WG_PROFILE:-proton}"
VPN_INTERFACE="${VPN_INTERFACE:-$WG_PROFILE}"
NATPMP_GATEWAY="${NATPMP_GATEWAY:-10.2.0.1}"
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/${WG_PROFILE}.conf}"
WG_IPV6_ENABLED="${WG_IPV6_ENABLED:-off}"
STATE_DIR="${STATE_DIR:-/run/proton}"
WG_RUNTIME_DIR="${WG_RUNTIME_DIR:-/etc/wireguard/proton-runtime}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
SERVER_RESELECT_FILE="${SERVER_RESELECT_FILE:-${STATE_DIR}/reselect-server.flag}"
SERVER_POOL_ENABLED="${SERVER_POOL_ENABLED:-auto}"
SERVER_MANAGER_SCRIPT="${SERVER_MANAGER_SCRIPT:-/usr/local/bin/proton/proton-server-manager.sh}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"
KILLSWITCH_SCRIPT="${KILLSWITCH_SCRIPT:-/usr/local/bin/proton/proton-killswitch-dispatch.sh}"
VPN_FWMARK="${VPN_FWMARK:-0xca6c}"
VPN_TABLE="${VPN_TABLE:-51820}"
DOCKER_NETWORK_CIDR="${DOCKER_NETWORK_CIDR:-}"
PREVIOUS_WG_PROFILE="$WG_PROFILE"
PREVIOUS_WG_CONFIG=""
WG_CONFIG_TO_USE="$WG_CONFIG"
FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"

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

for cmd in awk chmod cut ip mkdir mktemp mv rm systemd-cat wg-quick; do
    require_command "$cmd"
done

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
mkdir -p "$WG_RUNTIME_DIR"
chmod 700 "$WG_RUNTIME_DIR"

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
    if [[ -f "$SERVER_SELECTION_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SERVER_SELECTION_FILE"
        PREVIOUS_WG_PROFILE="${SELECTED_WG_PROFILE:-$WG_PROFILE}"
        PREVIOUS_WG_CONFIG="${SELECTED_CONFIG:-}"
    fi

    if ! server_pool_requested; then
        return 0
    fi

    if [[ ! -x "$SERVER_MANAGER_SCRIPT" ]]; then
        log "ERROR: Server manager script is not executable: $SERVER_MANAGER_SCRIPT"
        exit 1
    fi

    if [[ ! -f "$SERVER_SELECTION_FILE" || -f "$SERVER_RESELECT_FILE" ]]; then
        "$SERVER_MANAGER_SCRIPT" select >/dev/null
    fi

    if [[ -f "$SERVER_SELECTION_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SERVER_SELECTION_FILE"
        WG_PROFILE="${SELECTED_WG_PROFILE:-$WG_PROFILE}"
        VPN_INTERFACE="${SELECTED_VPN_INTERFACE:-$VPN_INTERFACE}"
        WG_CONFIG="${SELECTED_CONFIG:-$WG_CONFIG}"
        FILTERED_CONFIG_PATH="${WG_RUNTIME_DIR}/${WG_PROFILE}.conf"
    fi
}

ipv6_enabled() {
    case "$WG_IPV6_ENABLED" in
        1|true|yes|on)
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

ipv4_only_csv() {
    local csv="$1"
    local old_ifs part trimmed result=""

    old_ifs="$IFS"
    IFS=','
    for part in $csv; do
        trimmed="$(trim_field "$part")"
        if [[ "$trimmed" == *:* ]]; then
            continue
        fi
        if [[ -n "$trimmed" ]]; then
            if [[ -n "$result" ]]; then
                result="${result}, ${trimmed}"
            else
                result="$trimmed"
            fi
        fi
    done
    IFS="$old_ifs"

    printf '%s\n' "$result"
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

    awk -v keep_ipv6="$keep_ipv6" '
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

        /^[[:space:]]*\[/ {
            flush_interface_defaults()
            in_interface = ($0 ~ /^[[:space:]]*\[Interface\][[:space:]]*$/)
            table_written = in_interface ? 0 : 1
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
        }
    ' "$source_config" > "$tmp_config"

    chmod 600 "$tmp_config"
    mv -f "$tmp_config" "$FILTERED_CONFIG_PATH"
    WG_CONFIG_TO_USE="$FILTERED_CONFIG_PATH"
}

load_selected_server
prepare_wg_config "$WG_CONFIG"

log "Bringing up WireGuard profile $WG_PROFILE..."

if [[ -n "$PREVIOUS_WG_CONFIG" && -f "$PREVIOUS_WG_CONFIG" ]]; then
    wg-quick down "$PREVIOUS_WG_CONFIG" 2>/dev/null || true
else
    wg-quick down "$PREVIOUS_WG_PROFILE" 2>/dev/null || true
fi

if [[ -x "$KILLSWITCH_SCRIPT" ]]; then
    "$KILLSWITCH_SCRIPT"
fi

wg-quick up "$WG_CONFIG_TO_USE"

inject_routes() {
    # Attempt to auto-detect a Docker 'starr' network subnet if DOCKER_NETWORK_CIDR
    # was not provided and the docker CLI is available. This helps when the
    # qBittorrent container lives on a starr network and you want container
    # traffic forced through the VPN.
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
    # Remove any stale routes from a previous interface before installing
    # new ones.  On pool failover the old interface is gone but its routes
    # linger in the main table until explicitly deleted.
    if [[ -n "$DOCKER_NETWORK_CIDR" ]]; then
        ip route del "$DOCKER_NETWORK_CIDR" 2>/dev/null || true
    fi
    ip route del "$NATPMP_GATEWAY" 2>/dev/null || true

    # Clean stale rules first (avoid duplicates)
    ip rule del fwmark "$VPN_FWMARK" lookup "$VPN_TABLE" priority 100 2>/dev/null || true
    ip rule add fwmark "$VPN_FWMARK" lookup "$VPN_TABLE" priority 100
    ip route replace default dev "$VPN_INTERFACE" table "$VPN_TABLE"
    # NATPMP gateway must be reachable inside the tunnel table too.
    ip route replace "$NATPMP_GATEWAY" dev "$VPN_INTERFACE" table "$VPN_TABLE"
    # Keep the direct host route in the main table for the killswitch
    # endpoint-allow rule and natpmpc to work without fwmark.
    ip route replace "$NATPMP_GATEWAY" dev "$VPN_INTERFACE" 2>/dev/null || true

    # If Docker network CIDR is provided, use a source-based rule so container-sourced
    # traffic is forced into the VPN table (more reliable than a simple dev route).
    if [[ -n "$DOCKER_NETWORK_CIDR" ]]; then
        # remove any previous rule then add a source-rule
        ip rule del from "$DOCKER_NETWORK_CIDR" lookup "$VPN_TABLE" priority 110 2>/dev/null || true
        ip rule add from "$DOCKER_NETWORK_CIDR" lookup "$VPN_TABLE" priority 110
        ip route replace "$DOCKER_NETWORK_CIDR" dev "$VPN_INTERFACE" table "$VPN_TABLE" 2>/dev/null || true
        log "Docker network $DOCKER_NETWORK_CIDR routed via $VPN_INTERFACE table $VPN_TABLE"
    fi

    log "Policy routing: fwmark $VPN_FWMARK -> table $VPN_TABLE via $VPN_INTERFACE"
}

inject_routes

sleep 5

IP="$(ip -4 addr show "$VPN_INTERFACE" | awk '/inet / {print $2}' | cut -d/ -f1 || true)"

if [[ -z "$IP" ]]; then
    log "ERROR: $VPN_INTERFACE came up without an IPv4 address"
    exit 1
fi

log "WireGuard up on $VPN_INTERFACE with IP: $IP"