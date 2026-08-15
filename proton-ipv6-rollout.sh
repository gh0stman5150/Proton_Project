#!/usr/bin/env bash
set -euo pipefail

STATE_ROOT="${PROTON_IPV6_ROLLBACK_DIR:-/var/lib/proton/ipv6-rollbacks}"
COMMON_ENV="${PROTON_COMMON_ENV:-/etc/proton/proton-common.env}"
INSTANCE_ROOT="${PROTON_INSTANCE_ROOT:-/etc/proton/instances}"
RUNTIME_ROOT="${PROTON_RUNTIME_ROOT:-/run/proton}"
WG_POOL_DIR="${WG_POOL_DIR:-/etc/wireguard/proton-pool}"
PROJECT_DIR="${PROTON_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
LIVE_DIR="${PROTON_LIVE_DIR:-/usr/local/bin/proton}"
DOCKER_NETWORK_NAME="${PROTON_DOCKER_NETWORK_NAME:-starr_network}"
SNAPSHOT_PATH=""
ROLLBACK_RESTORE_ROOT=""

log() {
	printf '%s\n' "$*"
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
Usage: proton-ipv6-rollout.sh COMMAND [SNAPSHOT]

Commands:
  status               Show IPv6 rollout and live network status (read-only)
  preflight            Verify that a safe rollout can be attempted (read-only)
	canary-preflight NAME Verify one instance is ready for a tunnel-only canary
	activate-canary NAME Enable and verify one tunnel-only IPv6 canary
	deactivate-canary NAME Restore one canary to IPv4-only mode
  docker-preflight CIDR Verify Docker dual-stack prerequisites (read-only)
  snapshot             Capture files and live state needed for rollback
  rollback SNAPSHOT    Restore a snapshot and restart previously active services

Docker preflight does not enable forwarding, apply firewall rules, restart
services, or modify the shared Docker network.
EOF
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "Required command is missing: $1"
}

require_root() {
	[[ "$EUID" -eq 0 ]] || die "This command must run as root"
}

env_value() {
	local name="$1"
	local file="${2:-$COMMON_ENV}"

	[[ -f "$file" ]] || return 0
	awk -F= -v wanted="$name" '
		$0 !~ /^[[:space:]]*#/ && $1 == wanted {
			value = substr($0, index($0, "=") + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			print value
			exit
		}
	' "$file"
}

ipv6_is_enabled() {
	case "$(env_value WG_IPV6_ENABLED)" in
	1 | true | yes | on) return 0 ;;
	*) return 1 ;;
	esac
}

status() {
	local docker_ipv6="unavailable"

	if command -v docker >/dev/null 2>&1; then
		docker_ipv6="$(docker network inspect starr_network --format '{{.EnableIPv6}}' 2>/dev/null || printf 'unknown')"
	fi

	printf 'WG_IPV6_ENABLED=%s\n' "$(env_value WG_IPV6_ENABLED || true)"
	printf 'starr_network.EnableIPv6=%s\n' "$docker_ipv6"
	printf '%s\n' 'IPv6 policy rules:'
	ip -6 rule show 2>/dev/null || true
	printf '%s\n' 'IPv6 default routes:'
	ip -6 route show default 2>/dev/null || true
}

preflight() {
	local failed=0
	local backend

	for command in awk docker ip nft systemctl tar; do
		if ! command -v "$command" >/dev/null 2>&1; then
			printf 'FAIL: required command is missing: %s\n' "$command" >&2
			failed=1
		fi
	done

	backend="$(env_value KILLSWITCH_BACKEND || true)"
	case "${backend:-auto}" in
	auto | nft | nftables) ;;
	*)
		printf 'FAIL: IPv6 rollout requires the nftables kill-switch backend; found %s\n' "$backend" >&2
		failed=1
		;;
	esac

	if ipv6_is_enabled; then
		printf '%s\n' 'FAIL: WG_IPV6_ENABLED is already on; refusing to establish an unverified baseline' >&2
		failed=1
	fi

	if command -v docker >/dev/null 2>&1 &&
		[[ "$(docker network inspect starr_network --format '{{.EnableIPv6}}' 2>/dev/null || true)" == "true" ]]; then
		printf '%s\n' 'FAIL: starr_network already has IPv6 enabled; current state is not the expected IPv4-only baseline' >&2
		failed=1
	fi

	if [[ -d /archive ]] || [[ -d "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/archive" ]]; then
		printf '%s\n' 'INFO: archive directory exists and must be reviewed before activation'
	else
		printf '%s\n' 'INFO: /archive is absent; no archive comparison is available'
	fi

	((failed == 0)) || return 1
	printf '%s\n' 'PASS: IPv4-only baseline is intact; snapshot may proceed'
}

validate_docker_ipv6_cidr() {
	local cidr="$1"

	python3 - "$cidr" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.ip_network(sys.argv[1], strict=True)
except ValueError:
    raise SystemExit(1)

ula = ipaddress.ip_network("fc00::/7")
raise SystemExit(0 if network.version == 6 and network.prefixlen == 64 and network.subnet_of(ula) else 1)
PY
}

ipv6_cidr_input_overlaps() {
	local cidr="$1"

	python3 -c '
import ipaddress
import sys

proposed = ipaddress.ip_network(sys.argv[1])
for line in sys.stdin:
	for field in line.split():
		try:
			candidate = ipaddress.ip_network(field, strict=False)
		except ValueError:
			continue
		if candidate.version == 6 and proposed.overlaps(candidate):
			raise SystemExit(0)
raise SystemExit(1)
' "$cidr"
}

docker_preflight() {
	local cidr="${1:-}"
	local backend docker_ipv6 forwarding default_forwarding script
	local failed=0
	local -a firewall_scripts=(
		proton-killswitch-nft.sh
		proton-killswitch-safe.sh
		proton-killswitch-reset.sh
		proton-wg-up-safe.sh
		proton-wg-down-safe.sh
		proton-docker-network-watcher.sh
	)

	for command in cmp docker ip nft python3 sysctl; do
		if ! command -v "$command" >/dev/null 2>&1; then
			printf 'FAIL: required command is missing: %s\n' "$command" >&2
			failed=1
		fi
	done
	((failed == 0)) || return 1

	[[ -n "$cidr" ]] || {
		printf '%s\n' 'FAIL: docker-preflight requires an explicit IPv6 CIDR' >&2
		return 1
	}
	if ! validate_docker_ipv6_cidr "$cidr"; then
		printf 'FAIL: Docker IPv6 CIDR must be a canonical ULA /64: %s\n' "$cidr" >&2
		failed=1
	fi

	backend="$(env_value KILLSWITCH_BACKEND || true)"
	case "$backend" in
	nft | nftables) ;;
	*)
		printf 'FAIL: Docker IPv6 requires explicit KILLSWITCH_BACKEND=nftables; found %s\n' "${backend:-unset}" >&2
		failed=1
		;;
	esac

	docker_ipv6="$(docker network inspect "$DOCKER_NETWORK_NAME" --format '{{.EnableIPv6}}' 2>/dev/null || true)"
	[[ "$docker_ipv6" == "false" ]] || {
		printf 'FAIL: %s must exist and remain IPv4-only before activation\n' "$DOCKER_NETWORK_NAME" >&2
		failed=1
	}

	forwarding="$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || true)"
	default_forwarding="$(sysctl -n net.ipv6.conf.default.forwarding 2>/dev/null || true)"
	if [[ "$forwarding" != 0 || "$default_forwarding" != 0 ]]; then
		printf 'FAIL: IPv6 forwarding baseline must remain off before activation; all=%s default=%s\n' \
			"${forwarding:-unknown}" "${default_forwarding:-unknown}" >&2
		failed=1
	fi

	for script in "${firewall_scripts[@]}"; do
		if [[ ! -f "$PROJECT_DIR/$script" || ! -f "$LIVE_DIR/$script" ]] ||
			! cmp -s "$PROJECT_DIR/$script" "$LIVE_DIR/$script"; then
			printf 'FAIL: tested and installed Docker IPv6 scripts differ: %s\n' "$script" >&2
			failed=1
		fi
	done

	if ip -6 route show table all 2>/dev/null | ipv6_cidr_input_overlaps "$cidr"; then
		printf 'FAIL: proposed Docker IPv6 CIDR overlaps an existing host route: %s\n' "$cidr" >&2
		failed=1
	fi

	if docker network ls -q | while IFS= read -r network_id; do
		docker network inspect "$network_id" --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' 2>/dev/null || true
	done | ipv6_cidr_input_overlaps "$cidr"; then
		printf 'FAIL: proposed Docker IPv6 CIDR overlaps an existing Docker network: %s\n' "$cidr" >&2
		failed=1
	fi

	nft list table inet proton >/dev/null 2>&1 || {
		printf '%s\n' 'FAIL: active nftables table inet proton is not readable' >&2
		failed=1
	}

	((failed == 0)) || return 1
	printf 'PASS: Docker IPv6 preflight is clean for %s; no live state was changed\n' "$cidr"
	printf 'NEXT: create a fresh rollout snapshot before any activation work\n'
}

validate_instance_name() {
	case "$1" in
	lidarr | radarr | sonarr | whisparr | prowlarr) ;;
	*) die "Unsupported canary instance: $1" ;;
	esac
}

canary_preflight() {
	local instance="${1:-}"
	local latest selected_file selected_config selected_name instance_env enabled_count=0
	local docker_ipv6

	validate_instance_name "$instance"
	for command in docker nft tar; do
		require_command "$command"
	done

	latest="$(readlink -f "${STATE_ROOT}/latest" 2>/dev/null || true)"
	[[ -n "$latest" && "$latest" == "$(readlink -f "$STATE_ROOT")"/* ]] ||
		die "No valid latest snapshot exists below $STATE_ROOT"
	[[ -f "${latest}/payload.tar.gz" && -f "${latest}/manifest/active-services.txt" ]] ||
		die "Latest snapshot is incomplete: $latest"
	tar -tzf "${latest}/payload.tar.gz" >/dev/null ||
		die "Latest snapshot payload is unreadable: $latest"

	if ipv6_is_enabled; then
		die "Global WG_IPV6_ENABLED must remain off for a single-instance canary"
	fi

	docker_ipv6="$(docker network inspect starr_network --format '{{.EnableIPv6}}' 2>/dev/null || true)"
	[[ "$docker_ipv6" == "false" ]] ||
		die "starr_network must remain IPv4-only during the tunnel canary"

	while IFS= read -r instance_env; do
		case "$(env_value WG_IPV6_ENABLED "$instance_env")" in
		1 | true | yes | on) enabled_count=$((enabled_count + 1)) ;;
		esac
	done < <(find "$INSTANCE_ROOT" -mindepth 2 -maxdepth 2 -type f -name proton.env 2>/dev/null)
	((enabled_count <= 1)) || die "More than one instance has WG_IPV6_ENABLED enabled"

	instance_env="${INSTANCE_ROOT}/${instance}/proton.env"
	[[ -r "$instance_env" ]] || die "Instance environment is not readable: $instance_env"
	case "$(env_value WG_IPV6_ENABLED "$instance_env")" in
	1 | true | yes | on) ;;
	*) die "$instance must explicitly set WG_IPV6_ENABLED=on" ;;
	esac

	selected_file="${RUNTIME_ROOT}/${instance}/current-server.env"
	[[ -r "$selected_file" ]] || die "Selected-server state is not readable: $selected_file"
	selected_config="$(env_value SELECTED_CONFIG "$selected_file")"
	selected_name="$(env_value SELECTED_WG_PROFILE "$selected_file")"
	[[ -n "$selected_config" && -f "$selected_config" ]] ||
		die "Selected WireGuard config is missing for $instance"
	[[ "$selected_config" == "$WG_POOL_DIR"/* ]] ||
		die "Selected config is outside WG_POOL_DIR: $selected_config"

	awk -F= '
		/^[[:space:]]*Address[[:space:]]*=/ && $2 ~ /:/ { address = 1 }
		/^[[:space:]]*DNS[[:space:]]*=/ && $2 ~ /:/ { dns = 1 }
		/^[[:space:]]*AllowedIPs[[:space:]]*=/ && $2 ~ /(^|,[[:space:]]*)::\/0([[:space:]]*,|[[:space:]]*$)/ { allowed = 1 }
		END { exit !(address && dns && allowed) }
	' "$selected_config" || die "Selected profile ${selected_name:-unknown} is not fully IPv6 capable"

	printf 'PASS: %s canary is ready on %s with Docker IPv6 still disabled\n' "$instance" "${selected_name:-unknown}"
	printf 'Rollback: %s rollback %s\n' "$0" "$latest"
}

set_env_value() {
	local file="$1"
	local name="$2"
	local value="$3"
	local tmp

	[[ -f "$file" ]] || die "Environment file not found: $file"
	tmp="$(mktemp "${file}.XXXXXX")"
	awk -F= -v wanted="$name" -v replacement="$value" '
		BEGIN { written = 0 }
		$1 == wanted {
			print wanted "=" replacement
			written = 1
			next
		}
		{ print }
		END {
			if (!written) print wanted "=" replacement
		}
	' "$file" >"$tmp"
	chown --reference="$file" "$tmp"
	chmod --reference="$file" "$tmp"
	mv -f "$tmp" "$file"
}

instance_units() {
	local instance="$1"
	printf '%s\n' \
		"proton-wg@${instance}.service" \
		"proton-port-forward@${instance}.service" \
		"proton-healthcheck@${instance}.service" \
		"proton-docker-watch@${instance}.service"
}

restart_instance() {
	local instance="$1"
	local -a units=()

	mapfile -t units < <(instance_units "$instance")
	systemctl daemon-reload
	systemctl restart "${units[@]}"
}

cleanup_rollback_restore_root() {
	if [[ -n "$ROLLBACK_RESTORE_ROOT" ]]; then
		rm -rf "$ROLLBACK_RESTORE_ROOT"
		ROLLBACK_RESTORE_ROOT=""
	fi
}

start_snapshot_services() {
	local -a active_services=("$@")
	local -a failed_services=()
	local unit prefix

	unit="proton-killswitch.service"
	if [[ " ${active_services[*]} " == *" $unit "* ]] && ! systemctl start "$unit"; then
		failed_services+=("$unit")
	fi

	for prefix in proton-wg@ proton-port-forward@ proton-healthcheck@ proton-docker-watch@; do
		for unit in "${active_services[@]}"; do
			[[ "$unit" == "$prefix"* ]] || continue
			if ! systemctl start "$unit"; then
				failed_services+=("$unit")
			fi
		done
	done

	for unit in "${active_services[@]}"; do
		case "$unit" in
		proton-killswitch.service | proton-wg@* | proton-port-forward@* | proton-healthcheck@* | proton-docker-watch@*)
			continue
			;;
		esac
		if ! systemctl start "$unit"; then
			failed_services+=("$unit")
		fi
	done

	if ((${#failed_services[@]} > 0)); then
		printf 'ERROR: Rollback restored files but these services failed to start: %s\n' "${failed_services[*]}" >&2
		return 1
	fi
}

deactivate_canary() {
	local instance="${1:-}"
	local instance_env

	require_root
	validate_instance_name "$instance"
	instance_env="${INSTANCE_ROOT}/${instance}/proton.env"
	set_env_value "$instance_env" WG_IPV6_ENABLED off
	restart_instance "$instance"
	printf 'PASS: %s restored to IPv4-only mode\n' "$instance"
}

activate_canary() {
	local instance="${1:-}"
	local instance_env backup vpn_if vpn_table public_ipv6 curl_error
	local failed=0
	local -a units=()

	require_root
	validate_instance_name "$instance"
	require_command curl
	instance_env="${INSTANCE_ROOT}/${instance}/proton.env"
	backup="${RUNTIME_ROOT}/${instance}/proton.env.pre-ipv6"
	[[ -f "$instance_env" ]] || die "Instance environment not found: $instance_env"
	mkdir -p "$(dirname "$backup")"
	cp -a "$instance_env" "$backup"
	set_env_value "$instance_env" WG_IPV6_ENABLED on

	if ! canary_preflight "$instance"; then
		cp -a "$backup" "$instance_env"
		die "Canary preflight failed; restored $instance environment without restarting services"
	fi

	vpn_if="$(env_value VPN_INTERFACE "$instance_env")"
	[[ -n "$vpn_if" ]] || die "VPN_INTERFACE is missing from $instance_env"
	vpn_table="$(env_value VPN_TABLE "$instance_env")"
	if [[ -z "$vpn_table" ]]; then
		local subnet
		subnet="$(env_value WG_ADDRESS_SUBNET "$instance_env")"
		[[ "$subnet" =~ ^[0-9]+$ ]] || die "Cannot derive VPN_TABLE for $instance"
		vpn_table="$((51800 + 10#$subnet))"
	fi
	mapfile -t units < <(instance_units "$instance")

	log "CANARY: restarting only $instance Proton services"
	if ! restart_instance "$instance"; then
		log "FAIL: service restart failed"
		failed=1
	fi

	if ! ip -6 addr show dev "$vpn_if" | grep -q 'inet6 2a07:b944:'; then
		log "FAIL: Proton IPv6 address is missing from $vpn_if"
		failed=1
	else
		log "PASS: Proton IPv6 address is present on $vpn_if"
	fi

	if ! ip -6 route show table "$vpn_table" | grep -q "default dev $vpn_if"; then
		log "FAIL: table $vpn_table has no IPv6 default through $vpn_if"
		failed=1
	else
		log "PASS: table $vpn_table routes IPv6 through $vpn_if"
	fi

	if ! ip -6 rule show | grep -Eq "oif ${vpn_if}.*lookup ${vpn_table}"; then
		log "FAIL: no bound-interface IPv6 policy rule selects table $vpn_table"
		failed=1
	else
		log "PASS: bound-interface IPv6 policy rule selects table $vpn_table"
	fi

	curl_error="$(mktemp)"
	if public_ipv6="$(curl --noproxy '*' --interface "$vpn_if" -6 -fsS \
		--connect-timeout 10 --max-time 20 https://api64.ipify.org 2>"$curl_error")" &&
		[[ "$public_ipv6" == *:* ]]; then
		log "PASS: outbound IPv6 succeeded through $vpn_if"
	else
		log "FAIL: outbound IPv6 probe failed through $vpn_if: $(tr '\n' ' ' <"$curl_error")"
		failed=1
	fi
	rm -f "$curl_error"

	for unit in "${units[@]}"; do
		if ! systemctl is-active --quiet "$unit"; then
			log "FAIL: unit is not active: $unit"
			failed=1
		fi
	done

	if ((failed)); then
		log "CANARY FAILED: restoring $instance to its saved IPv4-only environment"
		cp -a "$backup" "$instance_env"
		restart_instance "$instance" || true
		return 1
	fi

	log "CANARY PASS: $instance tunnel IPv6 is active; Docker IPv6 remains disabled"
}

record_command() {
	local output_file="$1"
	shift
	"$@" >"$output_file" 2>&1 || true
}

snapshot_path() {
	local path="$1"
	local payload="$2"
	local paths_file="$3"

	[[ "$path" == /* ]] || die "Snapshot path must be absolute: $path"
	if [[ -e "$path" || -L "$path" ]]; then
		printf 'present\t%s\n' "$path" >>"$paths_file"
		mkdir -p "${payload}$(dirname "$path")"
		cp -a "$path" "${payload}${path}"
	else
		printf 'absent\t%s\n' "$path" >>"$paths_file"
	fi
}

snapshot() {
	local timestamp payload manifest paths_file compose_path
	local -a snapshot_paths=(
		/etc/proton
		/etc/wireguard
		/etc/docker
		/usr/local/bin/proton
	)

	require_root
	preflight
	timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
	SNAPSHOT_PATH="${STATE_ROOT}/${timestamp}"
	payload="${SNAPSHOT_PATH}/payload"
	manifest="${SNAPSHOT_PATH}/manifest"
	paths_file="${manifest}/paths.tsv"

	umask 077
	mkdir -p "$payload" "$manifest"

	while IFS= read -r compose_path; do
		[[ -n "$compose_path" ]] || continue
		[[ "$compose_path" == /* ]] || die "QBT_COMPOSE_PROJECT_DIR must be absolute: $compose_path"
		snapshot_paths+=("$compose_path")
	done < <(
		grep -RhsE '^QBT_COMPOSE_PROJECT_DIR=' /etc/proton/instances 2>/dev/null |
			cut -d= -f2- | sort -u
	)

	for path in "${snapshot_paths[@]}"; do
		snapshot_path "$path" "$payload" "$paths_file"
	done

	mkdir -p "${payload}/etc/systemd/system"
	find /etc/systemd/system -maxdepth 1 -type f -name 'proton*.service' \
		-exec cp -a -t "${payload}/etc/systemd/system" {} + 2>/dev/null || true

	find /etc/systemd/system -maxdepth 1 -type l -name 'proton*.service' \
		-exec cp -a -t "${payload}/etc/systemd/system" {} + 2>/dev/null || true

	record_command "${manifest}/ip-rule.txt" ip rule show
	record_command "${manifest}/ip-route.txt" ip route show table all
	record_command "${manifest}/ip6-rule.txt" ip -6 rule show
	record_command "${manifest}/ip6-route.txt" ip -6 route show table all
	record_command "${manifest}/wg-show.txt" wg show
	record_command "${manifest}/nft-ruleset.txt" nft list ruleset
	record_command "${manifest}/docker-networks.json" docker network inspect starr_network
	systemctl list-units --state=active --plain --no-legend 'proton*.service' |
		awk '{print $1}' >"${manifest}/active-services.txt" || true
	systemctl list-unit-files --plain --no-legend 'proton*.service' \
		>"${manifest}/unit-files.txt" 2>&1 || true

	printf 'created_utc=%s\n' "$timestamp" >"${manifest}/snapshot.env"
	printf 'source_commit=%s\n' "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse HEAD 2>/dev/null || true)" >>"${manifest}/snapshot.env"
	printf 'wg_ipv6_enabled=%s\n' "$(env_value WG_IPV6_ENABLED || true)" >>"${manifest}/snapshot.env"

	tar -C "$SNAPSHOT_PATH" -czf "${SNAPSHOT_PATH}/payload.tar.gz" payload
	rm -rf "$payload"
	chmod -R go-rwx "$SNAPSHOT_PATH"
	ln -sfn "$SNAPSHOT_PATH" "${STATE_ROOT}/latest"
	log "Snapshot created: $SNAPSHOT_PATH"
}

rollback() {
	local requested="${1:-}"
	local state path
	local -a active_services=()
	local -a current_services=()

	require_root
	[[ -n "$requested" ]] || die "rollback requires a snapshot path"
	requested="$(readlink -f "$requested")"
	[[ "$requested" == "$(readlink -f "$STATE_ROOT")"/* ]] || die "Snapshot must be below $STATE_ROOT"
	[[ -f "${requested}/payload.tar.gz" ]] || die "Snapshot payload not found: $requested"

	ROLLBACK_RESTORE_ROOT="$(mktemp -d)"
	trap cleanup_rollback_restore_root EXIT
	tar -C "$ROLLBACK_RESTORE_ROOT" -xzf "${requested}/payload.tar.gz"

	mapfile -t active_services < <(cat "${requested}/manifest/active-services.txt" 2>/dev/null || true)
	mapfile -t current_services < <(
		systemctl list-units --state=active --plain --no-legend 'proton*.service' 2>/dev/null |
			awk '{print $1}'
	)
	if ((${#current_services[@]} > 0)); then
		systemctl stop "${current_services[@]}" || true
	fi

	while IFS=$'\t' read -r state path; do
		[[ "$path" == /* ]] || die "Invalid path in snapshot manifest: $path"
		rm -rf "$path"
		if [[ "$state" == "present" ]]; then
			[[ -e "${ROLLBACK_RESTORE_ROOT}/payload${path}" || -L "${ROLLBACK_RESTORE_ROOT}/payload${path}" ]] ||
				die "Snapshot payload is incomplete for $path"
			mkdir -p "$(dirname "$path")"
			cp -a "${ROLLBACK_RESTORE_ROOT}/payload${path}" "$path"
		elif [[ "$state" != "absent" ]]; then
			die "Invalid state in snapshot manifest for $path: $state"
		fi
	done <"${requested}/manifest/paths.tsv"

	find /etc/systemd/system -maxdepth 1 \( -type f -o -type l \) -name 'proton*.service' -delete
	if [[ -d "${ROLLBACK_RESTORE_ROOT}/payload/etc/systemd/system" ]]; then
		cp -a "${ROLLBACK_RESTORE_ROOT}/payload/etc/systemd/system/." /etc/systemd/system/
	fi

	systemctl daemon-reload
	if ((${#active_services[@]} > 0)); then
		start_snapshot_services "${active_services[@]}"
	fi
	cleanup_rollback_restore_root
	trap - EXIT
	log "Rollback restored: $requested"
}

main() {
	require_command awk
	require_command ip

	case "${1:-}" in
	status) status ;;
	preflight) preflight ;;
	canary-preflight) canary_preflight "${2:-}" ;;
	activate-canary) activate_canary "${2:-}" ;;
	deactivate-canary) deactivate_canary "${2:-}" ;;
	docker-preflight) docker_preflight "${2:-}" ;;
	snapshot) snapshot ;;
	rollback) rollback "${2:-}" ;;
	-h | --help | help | '') usage ;;
	*) die "Unknown command: $1" ;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
