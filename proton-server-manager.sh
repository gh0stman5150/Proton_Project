#!/usr/bin/env bash
set -euo pipefail

LOG_TAG="${LOG_TAG:-proton-server}"
STATE_DIR="${STATE_DIR:-/run/proton}"
SERVER_SELECTION_FILE="${SERVER_SELECTION_FILE:-${STATE_DIR}/current-server.env}"
BAD_SERVER_FILE="${BAD_SERVER_FILE:-${STATE_DIR}/bad-servers.tsv}"
SERVER_RESELECT_FILE="${SERVER_RESELECT_FILE:-${STATE_DIR}/reselect-server.flag}"
WG_PROFILE="${WG_PROFILE:-proton}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"
BAD_SERVER_COOLDOWN="${BAD_SERVER_COOLDOWN:-900}"
SERVER_SWITCH_MIN_IMPROVEMENT_MS="${SERVER_SWITCH_MIN_IMPROVEMENT_MS:-10}"
SERVER_SWITCH_DEGRADED_LATENCY_MS="${SERVER_SWITCH_DEGRADED_LATENCY_MS:-75}"
PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-1}"
PING_COUNT="${PING_COUNT:-1}"
LOCK_FILE="${LOCK_FILE:-${STATE_DIR}/server-manager.lock}"
SERVER_POOL_STRICT_LINT="${SERVER_POOL_STRICT_LINT:-on}"
WG_EXPECTED_DNS="${WG_EXPECTED_DNS:-10.2.0.1}"
WG_LINT_ALLOW_MISSING_DNS="${WG_LINT_ALLOW_MISSING_DNS:-off}"

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

require_common_tools() {
	local cmd

	for cmd in awk chmod date flock mkdir mv rm; do
		require_command "$cmd"
	done
}

require_selection_tools() {
	local cmd

	for cmd in basename getent ping; do
		require_command "$cmd"
	done
}

require_common_tools

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

candidate_configs() {
	if compgen -G "$WG_POOL_DIR/*.conf" >/dev/null; then
		printf '%s\n' "$WG_POOL_DIR"/*.conf
		return 0
	fi

	printf '%s\n' "/etc/wireguard/${WG_PROFILE}.conf"
}

lint_targets() {
	local target="${1:-}"
	local config profile matched=0

	if [[ -z "$target" ]]; then
		candidate_configs
		return 0
	fi

	if [[ -f "$target" ]]; then
		printf '%s\n' "$target"
		return 0
	fi

	while IFS= read -r config; do
		[[ -f "$config" ]] || continue
		profile="$(config_profile "$config")"
		if [[ "$profile" == "$target" || "$(basename "$config")" == "$target" ]]; then
			printf '%s\n' "$config"
			matched=1
		fi
	done < <(candidate_configs)

	if [[ "$matched" -eq 0 ]]; then
		echo "ERROR: No WireGuard profile matched '$target'." >&2
		exit 1
	fi
}

config_profile() {
	basename "$1" .conf
}

selection_value() {
	local key="$1"

	[[ -f "$SERVER_SELECTION_FILE" ]] || return 1

	awk -F '=' -v key="$key" '
        $1 == key {
            print substr($0, index($0, "=") + 1)
            exit
        }
    ' "$SERVER_SELECTION_FILE"
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

trim_field() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s\n' "$value"
}

normalize_csv() {
	local csv="$1"
	local old_ifs part trimmed out=""

	old_ifs="$IFS"
	IFS=','
	for part in $csv; do
		trimmed="$(trim_field "$part")"
		[[ -n "$trimmed" ]] || continue
		if [[ -n "$out" ]]; then
			out="${out}, ${trimmed}"
		else
			out="$trimmed"
		fi
	done
	IFS="$old_ifs"

	printf '%s\n' "$out"
}

strict_lint_enabled() {
	case "$SERVER_POOL_STRICT_LINT" in
	1 | true | yes | on)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

allow_missing_dns() {
	case "$WG_LINT_ALLOW_MISSING_DNS" in
	1 | true | yes | on)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

config_dns_value() {
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

config_disallowed_directives() {
	awk -F '=' '
        /^[[:space:]]*(PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=/ {
            key = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (!(key in seen)) {
                seen[key] = 1
                out = out == "" ? key : out ", " key
            }
        }
        END { print out }
    ' "$1"
}

config_lint_reason() {
	local config="$1"
	local disallowed dns_value normalized_dns normalized_expected_dns

	strict_lint_enabled || return 0

	disallowed="$(config_disallowed_directives "$config")"
	if [[ -n "$disallowed" ]]; then
		printf 'disallowed directives present: %s\n' "$disallowed"
		return 0
	fi

	dns_value="$(config_dns_value "$config")"
	if [[ -z "$dns_value" ]]; then
		if allow_missing_dns; then
			return 0
		fi

		printf 'missing DNS directive (expected %s)\n' "$WG_EXPECTED_DNS"
		return 0
	fi

	normalized_dns="$(normalize_csv "$dns_value")"
	normalized_expected_dns="$(normalize_csv "$WG_EXPECTED_DNS")"

	if [[ "$normalized_dns" != "$normalized_expected_dns" ]]; then
		printf 'unexpected DNS value: %s (expected %s)\n' "$normalized_dns" "$normalized_expected_dns"
	fi
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

prefer_current_selection() {
	local current_profile="$1"
	local current_config="$2"
	local current_endpoint_host="$3"
	local current_endpoint_ip="$4"
	local current_endpoint_port="$5"
	local current_latency_ms="$6"
	local best_profile="$7"
	local best_latency_ms="$8"
	local improvement_ms

	[[ -n "$current_profile" ]] || return 1
	[[ -n "$best_profile" ]] || return 1
	[[ "$current_profile" != "$best_profile" ]] || return 1
	[[ "$current_latency_ms" =~ ^[0-9]+$ ]] || return 1
	[[ "$best_latency_ms" =~ ^[0-9]+$ ]] || return 1

	if ((current_latency_ms >= SERVER_SWITCH_DEGRADED_LATENCY_MS)); then
		if ((best_latency_ms < current_latency_ms)); then
			log "Switching away from current server $current_profile because latency ${current_latency_ms}ms exceeds degraded threshold ${SERVER_SWITCH_DEGRADED_LATENCY_MS}ms"
			return 1
		fi

		log "Keeping current server $current_profile despite degraded latency ${current_latency_ms}ms because no better candidate was available"
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$current_profile" \
			"$current_config" \
			"$current_endpoint_host" \
			"$current_endpoint_ip" \
			"$current_endpoint_port" \
			"$current_latency_ms"
		return 0
	fi

	improvement_ms=$((current_latency_ms - best_latency_ms))
	if ((improvement_ms < 0)); then
		improvement_ms=0
	fi

	if ((improvement_ms < SERVER_SWITCH_MIN_IMPROVEMENT_MS)); then
		log "Keeping current server $current_profile; best alternative only improves latency by ${improvement_ms}ms"
		printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$current_profile" \
			"$current_config" \
			"$current_endpoint_host" \
			"$current_endpoint_ip" \
			"$current_endpoint_port" \
			"$current_latency_ms"
		return 0
	fi

	return 1
}

save_selection() {
	local profile="$1"
	local config="$2"
	local endpoint_host="$3"
	local endpoint_ip="$4"
	local endpoint_port="$5"
	local latency_ms="$6"

	local tmp_file
	tmp_file="${SERVER_SELECTION_FILE}.tmp"

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
	} >"$tmp_file"

	chmod 600 "$tmp_file"
	mv -f "$tmp_file" "$SERVER_SELECTION_FILE"
}

select_best_server() {
	local allow_bad="${1:-0}"
	local best_profile=""
	local best_config=""
	local best_endpoint_host=""
	local best_endpoint_ip=""
	local best_endpoint_port=""
	local best_latency_ms=""
	local current_selected_profile=""
	local current_profile=""
	local current_config=""
	local current_endpoint_host=""
	local current_endpoint_ip=""
	local current_endpoint_port=""
	local current_latency_ms=""
	local preferred_selection=""
	local config

	require_selection_tools
	cleanup_bad_servers
	current_selected_profile="$(selection_value SELECTED_WG_PROFILE || true)"

	while IFS= read -r config; do
		local profile endpoint_host endpoint_ip endpoint_port latency_ms lint_reason

		[[ -f "$config" ]] || continue
		profile="$(config_profile "$config")"
		lint_reason="$(config_lint_reason "$config")"

		if [[ -n "$lint_reason" ]]; then
			log "Skipping $profile because it failed config lint: $lint_reason"
			continue
		fi

		if [[ "$allow_bad" != "1" ]] && server_is_bad "$profile"; then
			log "Skipping cooling-down server $profile"
			continue
		fi

		endpoint_host="$(config_endpoint_host "$config")"
		endpoint_port="$(config_endpoint_port "$config")"
		endpoint_ip="$(resolve_endpoint_ip "$endpoint_host" || true)"

		if [[ -z "$endpoint_host" || -z "$endpoint_port" || -z "$endpoint_ip" ]]; then
			log "Skipping $profile because its endpoint could not be resolved"
			continue
		fi

		latency_ms="$(measure_latency_ms "$endpoint_ip" || true)"
		if [[ -z "$latency_ms" ]]; then
			latency_ms=999999
			log "Latency probe failed for $profile, treating it as a fallback candidate"
		fi

		if [[ -n "$current_selected_profile" && "$profile" == "$current_selected_profile" ]]; then
			current_profile="$profile"
			current_config="$config"
			current_endpoint_host="$endpoint_host"
			current_endpoint_ip="$endpoint_ip"
			current_endpoint_port="$endpoint_port"
			current_latency_ms="$latency_ms"
		fi

		if [[ -z "$best_latency_ms" || "$latency_ms" -lt "$best_latency_ms" ]]; then
			best_profile="$profile"
			best_config="$config"
			best_endpoint_host="$endpoint_host"
			best_endpoint_ip="$endpoint_ip"
			best_endpoint_port="$endpoint_port"
			best_latency_ms="$latency_ms"
		fi
	done < <(candidate_configs)

	if [[ -z "$best_profile" && "$allow_bad" != "1" ]]; then
		log "No healthy server candidates were available; retrying with cooling-down nodes"
		select_best_server 1
		return 0
	fi

	if [[ -z "$best_profile" ]]; then
		log "ERROR: No WireGuard profiles were available for selection."
		exit 1
	fi

	if preferred_selection="$(prefer_current_selection \
		"$current_profile" \
		"$current_config" \
		"$current_endpoint_host" \
		"$current_endpoint_ip" \
		"$current_endpoint_port" \
		"$current_latency_ms" \
		"$best_profile" \
		"$best_latency_ms")"; then
		IFS=$'\t' read -r \
			best_profile \
			best_config \
			best_endpoint_host \
			best_endpoint_ip \
			best_endpoint_port \
			best_latency_ms <<<"$preferred_selection"
	fi

	save_selection \
		"$best_profile" \
		"$best_config" \
		"$best_endpoint_host" \
		"$best_endpoint_ip" \
		"$best_endpoint_port" \
		"$best_latency_ms"

	rm -f "$SERVER_RESELECT_FILE"
	log "Selected server $best_profile (${best_endpoint_host}/${best_endpoint_ip}) with latency ${best_latency_ms}ms"
	cat "$SERVER_SELECTION_FILE"
}

lint_configs() {
	local target="${1:-}"
	local config profile lint_reason failed=0

	while IFS= read -r config; do
		[[ -f "$config" ]] || continue
		profile="$(config_profile "$config")"
		lint_reason="$(config_lint_reason "$config")"

		if [[ -n "$lint_reason" ]]; then
			printf 'FAIL\t%s\t%s\t%s\n' "$profile" "$config" "$lint_reason"
			failed=1
		else
			printf 'OK\t%s\t%s\n' "$profile" "$config"
		fi
	done < <(lint_targets "$target")

	return "$failed"
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
	# Acquire lock to prevent concurrent selection/writes
	exec 200>"$LOCK_FILE"
	flock 200
	select_best_server "${2:-0}"
	;;
current)
	if [[ -f "$SERVER_SELECTION_FILE" ]]; then
		cat "$SERVER_SELECTION_FILE"
	else
		select_best_server 0
	fi
	;;
lint)
	lint_configs "${2:-}"
	;;
mark-bad)
	# Acquire lock for marking bad servers (modifies state)
	exec 200>"$LOCK_FILE"
	flock 200
	mark_server_bad "${2:-}" "${3:-manual}"
	;;
show-bad)
	show_bad_servers
	;;
reset-bad)
	# Acquire lock for reset (modifies state)
	exec 200>"$LOCK_FILE"
	flock 200
	reset_bad_servers
	;;
*)
	echo "Usage: $0 {select|current|lint [profile]|mark-bad|show-bad|reset-bad}" >&2
	exit 1
	;;
esac
