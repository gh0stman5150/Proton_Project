#!/usr/bin/env bash
set -euo pipefail

COMMON_ENV_FILE="${PROTON_COMMON_ENV_FILE:-/etc/proton/proton-common.env}"
if [[ -f "$COMMON_ENV_FILE" ]]; then
	# shellcheck disable=SC1090
	source "$COMMON_ENV_FILE"
fi

LOG_TAG="${LOG_TAG:-proton-server}"
STATE_DIR="${STATE_DIR:-/run/proton}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
BAD_SERVER_FILE="${BAD_SERVER_FILE:-${STATE_DIR}/bad-servers.tsv}"
SERVER_RESELECT_FILE="${SERVER_RESELECT_FILE:-${STATE_DIR}/reselect-server.flag}"
WG_PROFILE="${WG_PROFILE:-proton}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"
BAD_SERVER_COOLDOWN="${BAD_SERVER_COOLDOWN:-900}"
PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-1}"
PING_COUNT="${PING_COUNT:-1}"
SERVER_SWITCH_MIN_IMPROVEMENT_MS="${SERVER_SWITCH_MIN_IMPROVEMENT_MS:-10}"
SERVER_SWITCH_DEGRADED_LATENCY_MS="${SERVER_SWITCH_DEGRADED_LATENCY_MS:-75}"
SERVER_POOL_STRICT_LINT="${SERVER_POOL_STRICT_LINT:-on}"
WG_IPV6_ENABLED="${WG_IPV6_ENABLED:-off}"
WG_EXPECTED_DNS="${WG_EXPECTED_DNS:-10.2.0.1}"
WG_LINT_ALLOW_MISSING_DNS="${WG_LINT_ALLOW_MISSING_DNS:-off}"
PORT_FORWARD_REQUIRED="${PORT_FORWARD_REQUIRED:-on}"
PF_CAPABLE_PROFILES_FILE="${PF_CAPABLE_PROFILES_FILE:-/etc/proton/pf-capable-profiles.tsv}"
PF_INCAPABLE_PROFILES_FILE="${PF_INCAPABLE_PROFILES_FILE:-/etc/proton/pf-incapable-profiles.tsv}"
PF_CLAIMS_FILE="${PF_CLAIMS_FILE:-/run/proton/pf-claims.tsv}"
# Default claim TTL (seconds) - increase to reduce race windows between concurrent selects
CLAIM_TTL="${CLAIM_TTL:-3600}"
# Consecutive port-forward incapability strikes tolerated before a server is
# evicted from the pool (added to the incapable list and its pool config
# deleted). Strikes are tracked globally and reset the instant a server proves
# it can forward a port, so only genuinely PF-incapable servers are removed.
PF_INCAPABLE_STRIKES_FILE="${PF_INCAPABLE_STRIKES_FILE:-/run/proton/pf-incapable-strikes.tsv}"
PF_INCAPABLE_STRIKE_THRESHOLD="${PF_INCAPABLE_STRIKE_THRESHOLD:-3}"
# Global lock serializing server selection across instances. Two instances must
# never select the same pool config concurrently: Proton keeps a single session
# per WireGuard key per endpoint, so a duplicate selection silently breaks
# NAT-PMP for the older tunnel. The lock makes snapshot+choose+claim atomic.
SERVER_SELECT_LOCK_FILE="${SERVER_SELECT_LOCK_FILE:-/run/proton/server-select.lock}"

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

require_common_tools() {
	local cmd

	for cmd in awk chmod date grep mkdir mv paste rm systemd-cat tr; do
		require_command "$cmd"
	done
}

require_selection_tools() {
	local cmd

	for cmd in basename getent ping; do
		require_command "$cmd"
	done
}

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

parent_dir() {
	local path="$1"

	if [[ "$path" == */* ]]; then
		printf '%s\n' "${path%/*}"
	else
		printf '.\n'
	fi
}

ensure_parent_directory() {
	ensure_directory "$(parent_dir "$1")" 700
}

profile_state_tmp_file() {
	local file="$1"

	printf '%s/.%s.tmp\n' "$STATE_DIR" "${file##*/}"
}

port_forward_required() {
	[[ "$PORT_FORWARD_REQUIRED" =~ ^(1|true|yes|on)$ ]]
}

profile_in_state_file() {
	local file="$1"
	local profile="$2"

	[[ -f "$file" ]] || return 1

	awk -F '\t' -v profile="$profile" '
        $1 == profile { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$file"
}

profile_state_count() {
	local file="$1"

	[[ -f "$file" ]] || {
		echo 0
		return 0
	}

	awk 'NF > 0 { count++ } END { print count + 0 }' "$file"
}

remove_profile_record() {
	local file="$1"
	local profile="$2"
	local tmp_file

	ensure_parent_directory "$file"
	tmp_file="$(profile_state_tmp_file "$file")"

	awk -F '\t' -v profile="$profile" '$1 != profile { print $0 }' "$file" 2>/dev/null >"$tmp_file" || true
	mv "$tmp_file" "$file"
	chmod 600 "$file"
}

write_profile_record() {
	local file="$1"
	local profile="$2"
	local detail="${3:-}"
	local note="${4:-}"
	local tmp_file

	ensure_parent_directory "$file"
	tmp_file="$(profile_state_tmp_file "$file")"

	awk -F '\t' -v profile="$profile" '$1 != profile { print $0 }' "$file" 2>/dev/null >"$tmp_file" || true
	{
		printf '%s\t%s' "$profile" "$(date +%s)"
		if [[ -n "$detail" ]]; then
			printf '\t%s' "$detail"
		fi
		if [[ -n "$note" ]]; then
			printf '\t%s' "$note"
		fi
		printf '\n'
	} >>"$tmp_file"
	mv "$tmp_file" "$file"
	chmod 600 "$file"
}

port_forward_allowlist_active() {
	port_forward_required || return 1
	[[ "$(profile_state_count "$PF_CAPABLE_PROFILES_FILE")" -gt 0 ]]
}

profile_is_capable() {
	local profile="$1"

	profile_in_state_file "$PF_CAPABLE_PROFILES_FILE" "$profile"
}

profile_is_incapable() {
	local profile="$1"

	profile_in_state_file "$PF_INCAPABLE_PROFILES_FILE" "$profile"
}

profile_port_forward_category() {
	local profile="$1"

	if ! port_forward_required; then
		echo "unrestricted"
		return 0
	fi

	if profile_is_incapable "$profile"; then
		echo "incapable"
	elif profile_is_capable "$profile"; then
		echo "proven-good"
	else
		echo "unproven"
	fi
}

profile_passes_port_forward_filter() {
	local profile="$1"
	local allow_unproven="${2:-0}"
	local category

	if ! port_forward_required; then
		return 0
	fi

	category="$(profile_port_forward_category "$profile")"

	case "$category" in
	incapable)
		log "Skipping $profile because it is marked port-forward incapable"
		return 1
		;;
	proven-good | unrestricted)
		return 0
		;;
	unproven)
		if port_forward_allowlist_active && [[ "$allow_unproven" != "1" ]]; then
			log "Skipping $profile because it is unproven and the selector is currently constrained to proven-good port-forward nodes"
			return 1
		fi
		return 0
		;;
	esac

	return 0
}

# Claim management: avoid selecting profiles that would forward the same
# external port already claimed by another instance. Claims are ephemeral
# and expire after $CLAIM_TTL seconds.
cleanup_claims() {
	local now tmp_file
	now="$(date +%s)"
	tmp_file="$(profile_state_tmp_file "$PF_CLAIMS_FILE")"

	if [[ -f "$PF_CLAIMS_FILE" ]]; then
		awk -F '\t' -v now="$now" -v ttl="$CLAIM_TTL" 'NF>=3 && ($2 + ttl) > now { print $0 }' "$PF_CLAIMS_FILE" >"$tmp_file" || true
		mv -f "$tmp_file" "$PF_CLAIMS_FILE"
		chmod 600 "$PF_CLAIMS_FILE"
	fi
}

get_profile_forward_port() {
	local profile="$1"
	if [[ -f "$PF_CAPABLE_PROFILES_FILE" ]]; then
		awk -F '\t' -v p="$profile" '$1 == p { print $3; exit }' "$PF_CAPABLE_PROFILES_FILE"
	fi
}

port_claimed_by() {
	local port="$1"
	if [[ -f "$PF_CLAIMS_FILE" && -n "$port" ]]; then
		awk -F '\t' -v port="$port" '$3 == port { print $4; exit }' "$PF_CLAIMS_FILE"
	fi
}

profile_claimed_by() {
	local profile="$1"
	if [[ -f "$PF_CLAIMS_FILE" && -n "$profile" ]]; then
		awk -F '\t' -v p="$profile" '$1 == p { print $4; exit }' "$PF_CLAIMS_FILE"
	fi
}

endpoint_claimed_by() {
	local endpoint="$1"
	if [[ -f "$PF_CLAIMS_FILE" && -n "$endpoint" ]]; then
		awk -F '\t' -v ep="$endpoint" '$3 == ep { print $4; exit }' "$PF_CLAIMS_FILE"
	fi
}

claim_profile_port() {
	local profile="$1" port="$2"
	write_profile_record "$PF_CLAIMS_FILE" "$profile" "$port" "$instance_name"
	log "Claimed port $port for $instance_name via $profile"
}

remove_claim_for_profile() {
	local profile="$1"
	remove_profile_record "$PF_CLAIMS_FILE" "$profile"
}

require_common_tools

ensure_directory "$STATE_DIR" 700

candidate_configs() {
	if compgen -G "$WG_POOL_DIR/*.conf" >/dev/null; then
		printf '%s\n' "$WG_POOL_DIR"/*.conf
		return 0
	fi

	printf '%s\n' "/etc/wireguard/${WG_PROFILE}.conf"
}

config_profile() {
	basename "$1" .conf
}

config_endpoint_value() {
	awk -F '=' '/^[[:space:]]*Endpoint[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$1"
}

config_endpoint_host() {
	local endpoint
	endpoint="$(config_endpoint_value "$1")"
	endpoint="${endpoint%:*}"
	endpoint="${endpoint#[}"
	endpoint="${endpoint%]}"
	echo "$endpoint"
}

config_endpoint_port() {
	local endpoint
	endpoint="$(config_endpoint_value "$1")"
	echo "${endpoint##*:}"
}

config_dns_value() {
	awk -F '=' '/^[[:space:]]*DNS[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$1"
}

config_address_value() {
	awk -F '=' '/^[[:space:]]*Address[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$1"
}

config_allowed_ips_value() {
	awk -F '=' '/^[[:space:]]*AllowedIPs[[:space:]]*=/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}' "$1"
}

normalize_csv() {
	printf '%s' "$1" | tr ',' '\n' | awk '
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if ($0 != "") {
                print tolower($0)
            }
        }
    ' | paste -sd, -
}

ipv6_enabled() {
	[[ "$WG_IPV6_ENABLED" =~ ^(1|true|yes|on)$ ]]
}

normalize_dns_csv() {
	local keep_ipv6=0

	if ipv6_enabled; then
		keep_ipv6=1
	fi

	printf '%s' "$1" | tr ',' '\n' | awk -v keep_ipv6="$keep_ipv6" '
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if ($0 == "") {
                next
            }

            value = tolower($0)
            if (!keep_ipv6 && value ~ /:/) {
                next
            }

            out = out == "" ? value : out "," value
        }
        END { print out }
    '
}

strict_lint_enabled() {
	[[ "$SERVER_POOL_STRICT_LINT" =~ ^(1|true|yes|on)$ ]]
}

allow_missing_dns() {
	[[ "$WG_LINT_ALLOW_MISSING_DNS" =~ ^(1|true|yes|on)$ ]]
}

lint_config() {
	local config="$1"
	local dns_value expected_dns address_value allowed_ips_value

	if ipv6_enabled; then
		address_value="$(config_address_value "$config")"
		allowed_ips_value="$(normalize_csv "$(config_allowed_ips_value "$config")")"

		if [[ "$address_value" != *:* ]]; then
			log "Skipping $(config_profile "$config") because IPv6 mode requires a Proton-assigned IPv6 interface address"
			return 1
		fi

		if [[ ",${allowed_ips_value}," != *",::/0,"* ]]; then
			log "Skipping $(config_profile "$config") because IPv6 mode requires AllowedIPs ::/0"
			return 1
		fi
	fi

	strict_lint_enabled || return 0

	if grep -qiE '^[[:space:]]*(PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' "$config"; then
		log "Skipping $(config_profile "$config") because it contains disallowed WireGuard hooks or SaveConfig"
		return 1
	fi

	dns_value="$(normalize_dns_csv "$(config_dns_value "$config")")"
	expected_dns="$(normalize_dns_csv "$WG_EXPECTED_DNS")"

	if [[ -z "$dns_value" ]]; then
		if allow_missing_dns; then
			return 0
		fi
		log "Skipping $(config_profile "$config") because it is missing DNS"
		return 1
	fi

	if [[ -n "$expected_dns" && "$dns_value" != "$expected_dns" ]]; then
		log "Skipping $(config_profile "$config") because its DNS does not match WG_EXPECTED_DNS"
		return 1
	fi
}

mark_profile_capable() {
	local profile="${1:-}"
	local port="${2:-}"

	if [[ -z "$profile" ]]; then
		profile="$(current_profile)"
	fi

	if [[ -z "$profile" ]]; then
		log "ERROR: Cannot mark a blank profile port-forward capable"
		exit 1
	fi

	remove_profile_record "$PF_INCAPABLE_PROFILES_FILE" "$profile"
	write_profile_record "$PF_CAPABLE_PROFILES_FILE" "$profile" "${port:-unknown}"
	reset_incapable_strikes "$profile"
	log "Marked server $profile port-forward capable${port:+ on port $port}"
}

mark_profile_incapable() {
	local profile="${1:-}"
	local reason="${2:-manual}"

	if [[ -z "$profile" ]]; then
		profile="$(current_profile)"
	fi

	if [[ -z "$profile" ]]; then
		log "ERROR: Cannot mark a blank profile port-forward incapable"
		exit 1
	fi

	remove_profile_record "$PF_CAPABLE_PROFILES_FILE" "$profile"
	write_profile_record "$PF_INCAPABLE_PROFILES_FILE" "$profile" "$reason"
	: >"$SERVER_RESELECT_FILE"
	chmod 600 "$SERVER_RESELECT_FILE"
	log "Marked server $profile port-forward incapable ($reason)"
}

incapable_strike_count() {
	local profile="$1"

	[[ -f "$PF_INCAPABLE_STRIKES_FILE" ]] || {
		echo 0
		return 0
	}

	awk -F '\t' -v profile="$profile" '$1 == profile { count = $2 } END { print count + 0 }' "$PF_INCAPABLE_STRIKES_FILE"
}

set_incapable_strike_count() {
	local profile="$1"
	local count="$2"
	local tmp_file

	ensure_parent_directory "$PF_INCAPABLE_STRIKES_FILE"
	tmp_file="$(profile_state_tmp_file "$PF_INCAPABLE_STRIKES_FILE")"

	awk -F '\t' -v profile="$profile" '$1 != profile { print $0 }' "$PF_INCAPABLE_STRIKES_FILE" 2>/dev/null >"$tmp_file" || true
	printf '%s\t%s\t%s\n' "$profile" "$count" "$(date +%s)" >>"$tmp_file"
	mv "$tmp_file" "$PF_INCAPABLE_STRIKES_FILE"
	chmod 600 "$PF_INCAPABLE_STRIKES_FILE"
}

reset_incapable_strikes() {
	local profile="$1"

	[[ -f "$PF_INCAPABLE_STRIKES_FILE" ]] || return 0
	remove_profile_record "$PF_INCAPABLE_STRIKES_FILE" "$profile"
}

delete_pool_config() {
	local profile="$1"
	local config="$WG_POOL_DIR/$profile.conf"

	if [[ -f "$config" ]]; then
		rm -f "$config"
		log "Removed port-forward incapable pool config $config"
	fi
}

# Record one port-forward incapability strike for a profile. After
# PF_INCAPABLE_STRIKE_THRESHOLD consecutive strikes the profile is evicted from
# the pool: written to the incapable list and its pool config deleted. A profile
# that has already proven it can forward ports is never evicted this way -- its
# streak is cleared and it is only cooled down.
mark_incapable_attempt() {
	local profile="${1:-}"
	local reason="${2:-natpmp-timeout}"
	local strikes

	if [[ -z "$profile" ]]; then
		profile="$(current_profile)"
	fi

	if [[ -z "$profile" ]]; then
		log "ERROR: Cannot record a port-forward incapability strike for a blank profile"
		exit 1
	fi

	if profile_is_capable "$profile"; then
		reset_incapable_strikes "$profile"
		mark_server_bad "$profile" "$reason"
		log "Ignoring port-forward incapability strike for proven-good server $profile ($reason); cooled it down instead"
		return 0
	fi

	strikes="$(incapable_strike_count "$profile")"
	strikes=$((strikes + 1))

	if ((strikes >= PF_INCAPABLE_STRIKE_THRESHOLD)); then
		reset_incapable_strikes "$profile"
		remove_claim_for_profile "$profile" || true
		remove_profile_record "$PF_CAPABLE_PROFILES_FILE" "$profile"
		write_profile_record "$PF_INCAPABLE_PROFILES_FILE" "$profile" "$reason" "strikes=${PF_INCAPABLE_STRIKE_THRESHOLD}"
		delete_pool_config "$profile"
		: >"$SERVER_RESELECT_FILE"
		chmod 600 "$SERVER_RESELECT_FILE"
		log "Evicted server $profile after ${PF_INCAPABLE_STRIKE_THRESHOLD} consecutive port-forward failures ($reason); added to the incapable list and deleted its pool config"
	else
		set_incapable_strike_count "$profile" "$strikes"
		mark_server_bad "$profile" "$reason"
		log "Recorded port-forward incapability strike ${strikes}/${PF_INCAPABLE_STRIKE_THRESHOLD} for $profile ($reason)"
	fi
}

show_profile_state_file() {
	local file="$1"

	if [[ -f "$file" ]]; then
		cat "$file"
	fi
}

reset_profile_state_file() {
	local file="$1"
	local description="$2"

	rm -f "$file"
	log "Cleared ${description} state"
}

resolve_endpoint_ip() {
	local host="$1"

	if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "$host"
		return 0
	fi

	getent ahostsv4 "$host" | awk 'NR == 1 {print $1}'
}

cleanup_bad_servers() {
	local now tmp_file
	now="$(date +%s)"
	tmp_file="${STATE_DIR}/bad-servers.tmp"

	if [[ -f "$BAD_SERVER_FILE" ]]; then
		awk -F '\t' -v now="$now" 'NF >= 2 && $2 > now {print $0}' "$BAD_SERVER_FILE" >"$tmp_file"
		mv "$tmp_file" "$BAD_SERVER_FILE"
	else
		: >"$BAD_SERVER_FILE"
	fi

	chmod 600 "$BAD_SERVER_FILE"
}

server_is_bad() {
	local profile="$1"
	local now
	now="$(date +%s)"

	[[ -f "$BAD_SERVER_FILE" ]] || return 1

	awk -F '\t' -v profile="$profile" -v now="$now" '
        $1 == profile && $2 > now { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$BAD_SERVER_FILE"
}

measure_latency_ms() {
	local endpoint_ip="$1"

	ping -c "$PING_COUNT" -W "$PING_TIMEOUT_SECONDS" "$endpoint_ip" 2>/dev/null |
		awk -F '=' '
            /rtt|round-trip/ {
                gsub(/ ms/, "", $2)
                split($2, parts, "/")
                printf "%.0f\n", parts[2]
                exit
            }
        '
}

save_selection() {
	local profile="$1"
	local config="$2"
	local endpoint_host="$3"
	local endpoint_ip="$4"
	local endpoint_port="$5"
	local latency_ms="$6"

	umask 077
	{
		echo "SELECTED_WG_PROFILE=$profile"
		echo "SELECTED_VPN_INTERFACE=$profile"
		echo "SELECTED_CONFIG=$config"
		echo "SELECTED_ENDPOINT_HOST=$endpoint_host"
		echo "SELECTED_ENDPOINT_IP=$endpoint_ip"
		echo "SELECTED_ENDPOINT_PORT=$endpoint_port"
		echo "SELECTED_LATENCY_MS=$latency_ms"
		echo "SELECTED_AT=$(date +%s)"
	} >"$SERVER_SELECTION_FILE"
}

select_best_server() {
	local allow_bad="${1:-0}"
	local allow_unproven="${2:-0}"
	local best_profile=""
	local best_config=""
	local best_endpoint_host=""
	local best_endpoint_ip=""
	local best_endpoint_port=""
	local best_latency_ms=""
	local current_profile_name=""
	local current_config=""
	local current_endpoint_host=""
	local current_endpoint_ip=""
	local current_endpoint_port=""
	local current_latency_ms=""
	local config

	require_selection_tools
	cleanup_bad_servers
	# Remove expired port claims before choosing a server.
	cleanup_claims || true
	instance_name="$(basename "$STATE_DIR" || true)"
	if [[ -z "$instance_name" ]]; then
		instance_name="global"
	fi

	# Build a short-lived snapshot of active selections from other instances so
	# the selector will avoid choosing a profile or endpoint already in use.
	active_snapshot_temp="$(profile_state_tmp_file /run/proton/active-selections)"
	: >"$active_snapshot_temp"
	for sel in /run/proton/*/current-server.env; do
		[[ -f "$sel" ]] || continue
		sel_inst="$(basename "$(dirname "$sel")")"
		# skip our own instance selection file
		[[ "$sel_inst" == "$instance_name" ]] && continue
		sel_profile="$(awk -F '=' '/^SELECTED_WG_PROFILE=/ {print $2; exit}' "$sel" 2>/dev/null || true)"
		sel_epip="$(awk -F '=' '/^SELECTED_ENDPOINT_IP=/ {print $2; exit}' "$sel" 2>/dev/null || true)"
		if [[ -n "$sel_profile" ]]; then
			printf 'P\t%s\t%s\n' "$sel_profile" "$sel_inst" >>"$active_snapshot_temp"
		fi
		if [[ -n "$sel_epip" ]]; then
			printf 'E\t%s\t%s\n' "$sel_epip" "$sel_inst" >>"$active_snapshot_temp"
		fi
	done
	current_profile_name="$(current_profile)"

	while IFS= read -r config; do
		local profile endpoint_host endpoint_ip endpoint_port latency_ms

		[[ -f "$config" ]] || continue
		profile="$(config_profile "$config")"

		if [[ "$allow_bad" != "1" ]] && server_is_bad "$profile"; then
			log "Skipping cooling-down server $profile"
			continue
		fi

		if ! profile_passes_port_forward_filter "$profile" "$allow_unproven"; then
			continue
		fi

		if ! lint_config "$config"; then
			continue
		fi

		# If another instance already has this profile selected, skip it.
		if [[ -f "$active_snapshot_temp" ]]; then
			if awk -v p="$profile" '$1=="P" && $2==p { exit 0 } END { exit 1 }' "$active_snapshot_temp"; then
				log "Skipping $profile because it is currently selected by another instance (active snapshot)"
				continue
			fi
		fi

		# If the profile is explicitly claimed by another instance, skip it.
		claimer_profile="$(profile_claimed_by "$profile" || true)"
		if [[ -n "$claimer_profile" && "$claimer_profile" != "$instance_name" ]]; then
			log "Skipping $profile because it is claimed by $claimer_profile"
			continue
		fi

		endpoint_host="$(config_endpoint_host "$config")"
		endpoint_port="$(config_endpoint_port "$config")"
		endpoint_ip="$(resolve_endpoint_ip "$endpoint_host" || true)"

		if [[ -z "$endpoint_host" || -z "$endpoint_port" || -z "$endpoint_ip" ]]; then
			log "Skipping $profile because its endpoint could not be resolved"
			continue
		fi

		# If another instance currently uses the same endpoint IP, skip this profile.
		if [[ -f "$active_snapshot_temp" ]]; then
			if awk -v ip="$endpoint_ip" '$1=="E" && $2==ip { exit 0 } END { exit 1 }' "$active_snapshot_temp"; then
				log "Skipping $profile because its endpoint $endpoint_ip is currently in use by another instance (active snapshot)"
				continue
			fi
		fi

		# If this profile is associated with a known forwarded port, ensure
		# that port is not already claimed by another instance. If no port
		# is known, fall back to guarding the endpoint IP so multiple
		# instances don't pick the same backend server.
		candidate_port="$(get_profile_forward_port "$profile" || true)"
		if [[ -n "$candidate_port" ]]; then
			claimer="$(port_claimed_by "$candidate_port" || true)"
			if [[ -n "$claimer" && "$claimer" != "$instance_name" ]]; then
				log "Skipping $profile because forwarded port $candidate_port is claimed by $claimer"
				continue
			fi
		else
			claimer_ip="$(endpoint_claimed_by "$endpoint_ip" || true)"
			if [[ -n "$claimer_ip" && "$claimer_ip" != "$instance_name" ]]; then
				log "Skipping $profile because its endpoint $endpoint_ip is claimed by $claimer_ip"
				continue
			fi
		fi

		latency_ms="$(measure_latency_ms "$endpoint_ip" || true)"
		if [[ -z "$latency_ms" ]]; then
			latency_ms=999999
			log "Latency probe failed for $profile, treating it as a fallback candidate"
		fi

		if [[ -z "$best_latency_ms" || "$latency_ms" -lt "$best_latency_ms" ]]; then
			best_profile="$profile"
			best_config="$config"
			best_endpoint_host="$endpoint_host"
			best_endpoint_ip="$endpoint_ip"
			best_endpoint_port="$endpoint_port"
			best_latency_ms="$latency_ms"
		fi

		if [[ "$profile" == "$current_profile_name" ]]; then
			current_config="$config"
			current_endpoint_host="$endpoint_host"
			current_endpoint_ip="$endpoint_ip"
			current_endpoint_port="$endpoint_port"
			current_latency_ms="$latency_ms"
		fi
	done < <(candidate_configs)

	if [[ -z "$best_profile" && "$allow_unproven" != "1" ]] && port_forward_allowlist_active; then
		log "No eligible proven-good port-forward candidates were available; retrying with unproven nodes"
		select_best_server "$allow_bad" 1
		return $?
	fi

	if [[ -z "$best_profile" && "$allow_bad" != "1" ]]; then
		log "No healthy server candidates were available; retrying with cooling-down nodes"
		select_best_server 1 "$allow_unproven"
		return $?
	fi

	if [[ -z "$best_profile" ]]; then
		log "No pools available even with cooling-down nodes; aborting"
		log "ERROR: No WireGuard profiles were available for selection."
		exit 1
	fi

	if [[ -f "$SERVER_SELECTION_FILE" && -n "$current_config" && "$best_profile" != "$current_profile_name" ]] &&
		! server_is_bad "$current_profile_name"; then
		local improvement_ms
		improvement_ms=$((current_latency_ms - best_latency_ms))

		if ((current_latency_ms < SERVER_SWITCH_DEGRADED_LATENCY_MS && improvement_ms < SERVER_SWITCH_MIN_IMPROVEMENT_MS)); then
			log "Keeping current server $current_profile_name (${current_latency_ms}ms); best candidate $best_profile improves latency by only ${improvement_ms}ms"
			best_profile="$current_profile_name"
			best_config="$current_config"
			best_endpoint_host="$current_endpoint_host"
			best_endpoint_ip="$current_endpoint_ip"
			best_endpoint_port="$current_endpoint_port"
			best_latency_ms="$current_latency_ms"
		fi
	fi

	save_selection \
		"$best_profile" \
		"$best_config" \
		"$best_endpoint_host" \
		"$best_endpoint_ip" \
		"$best_endpoint_port" \
		"$best_latency_ms"

	# Remove any previous claim held by this instance for a different profile
	if [[ -n "$current_profile_name" && "$current_profile_name" != "$best_profile" ]]; then
		remove_claim_for_profile "$current_profile_name" || true
	fi

	# Claim the forwarded port (if known) so other instances avoid selecting
	# profiles that would forward the same external port.
	candidate_port="$(get_profile_forward_port "$best_profile" || true)"
	if [[ -n "$candidate_port" ]]; then
		claim_profile_port "$best_profile" "$candidate_port" || true
	else
		# No forwarded port known; claim the endpoint IP instead to prevent
		# other instances from selecting the same backend server.
		claim_profile_port "$best_profile" "$best_endpoint_ip" || true
	fi

	rm -f "$SERVER_RESELECT_FILE"
	log "Selected server $best_profile (${best_endpoint_host}/${best_endpoint_ip}) with latency ${best_latency_ms}ms"
	cat "$SERVER_SELECTION_FILE"
	# Cleanup active snapshot
	rm -f "$active_snapshot_temp" 2>/dev/null || true
}

current_profile() {
	if [[ -f "$SERVER_SELECTION_FILE" ]]; then
		awk -F '=' '/^SELECTED_WG_PROFILE=/ {print $2; exit}' "$SERVER_SELECTION_FILE"
		return 0
	fi

	echo "$WG_PROFILE"
}

mark_server_bad() {
	local profile="${1:-}"
	local reason="${2:-manual}"
	local expiry now tmp_file

	cleanup_bad_servers

	if [[ -z "$profile" ]]; then
		profile="$(current_profile)"
	fi

	now="$(date +%s)"
	expiry="$((now + BAD_SERVER_COOLDOWN))"
	tmp_file="${STATE_DIR}/bad-servers.tmp"

	awk -F '\t' -v profile="$profile" '$1 != profile {print $0}' "$BAD_SERVER_FILE" 2>/dev/null >"$tmp_file"
	printf '%s\t%s\t%s\n' "$profile" "$expiry" "$reason" >>"$tmp_file"
	mv "$tmp_file" "$BAD_SERVER_FILE"
	chmod 600 "$BAD_SERVER_FILE"
	: >"$SERVER_RESELECT_FILE"
	chmod 600 "$SERVER_RESELECT_FILE"

	log "Marked server $profile bad for ${BAD_SERVER_COOLDOWN}s ($reason)"
}

show_bad_servers() {
	cleanup_bad_servers
	cat "$BAD_SERVER_FILE"
}

reset_bad_servers() {
	rm -f "$BAD_SERVER_FILE"
	rm -f "$SERVER_RESELECT_FILE"
	log "Cleared bad-server cooldown state"
}

case "${1:-select}" in
select)
	# Serialize selection across all instances so two instances never pick
	# the same pool config (same WireGuard key) concurrently. Best-effort:
	# if the global lock cannot be opened (e.g. unprivileged test runs), log
	# and continue rather than failing the selection.
	if mkdir -p "$(dirname "$SERVER_SELECT_LOCK_FILE")" 2>/dev/null &&
		exec 209>"$SERVER_SELECT_LOCK_FILE" 2>/dev/null; then
		flock 209 || true
	else
		log "WARNING: could not acquire server-select lock $SERVER_SELECT_LOCK_FILE; proceeding without cross-instance serialization"
	fi
	select_best_server "${2:-0}"
	;;
current)
	if [[ -f "$SERVER_SELECTION_FILE" ]]; then
		cat "$SERVER_SELECTION_FILE"
	else
		if mkdir -p "$(dirname "$SERVER_SELECT_LOCK_FILE")" 2>/dev/null &&
			exec 209>"$SERVER_SELECT_LOCK_FILE" 2>/dev/null; then
			flock 209 || true
		else
			log "WARNING: could not acquire server-select lock $SERVER_SELECT_LOCK_FILE; proceeding without cross-instance serialization"
		fi
		select_best_server 0
	fi
	;;
mark-bad)
	mark_server_bad "${2:-}" "${3:-manual}"
	;;
show-bad)
	show_bad_servers
	;;
reset-bad)
	reset_bad_servers
	;;
mark-capable)
	mark_profile_capable "${2:-}" "${3:-}"
	;;
mark-incapable)
	mark_profile_incapable "${2:-}" "${3:-manual}"
	;;
mark-incapable-attempt)
	mark_incapable_attempt "${2:-}" "${3:-natpmp-timeout}"
	;;
show-incapable-strikes)
	show_profile_state_file "$PF_INCAPABLE_STRIKES_FILE"
	;;
reset-incapable-strikes)
	reset_profile_state_file "$PF_INCAPABLE_STRIKES_FILE" "port-forward incapability strike"
	;;
show-capable)
	show_profile_state_file "$PF_CAPABLE_PROFILES_FILE"
	;;
show-incapable)
	show_profile_state_file "$PF_INCAPABLE_PROFILES_FILE"
	;;
reset-capable)
	reset_profile_state_file "$PF_CAPABLE_PROFILES_FILE" "port-forward capable"
	;;
reset-incapable)
	reset_profile_state_file "$PF_INCAPABLE_PROFILES_FILE" "port-forward incapable"
	;;
*)
	echo "Usage: $0 {select|current|mark-bad|show-bad|reset-bad|mark-capable|mark-incapable|mark-incapable-attempt|show-capable|show-incapable|show-incapable-strikes|reset-capable|reset-incapable|reset-incapable-strikes}" >&2
	exit 1
	;;
esac
