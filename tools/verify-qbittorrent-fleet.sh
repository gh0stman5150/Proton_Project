#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_ROOT="${QBT_COMPOSE_ROOT:-/opt}"
PROTON_INSTANCE_ROOT="${PROTON_INSTANCE_ROOT:-/etc/proton/instances}"
RUNTIME_ROOT="${PROTON_RUNTIME_ROOT:-/run/proton}"
COMMON_DIR="${QBT_COMMON_DIR:-${COMPOSE_ROOT}/qbittorrent-common}"
COMMON_COMPOSE_FILE="${QBT_COMMON_COMPOSE_FILE:-${COMMON_DIR}/docker-compose.common.yml}"
MANIFEST_FILE="${QBT_INSTANCE_MANIFEST:-${COMMON_DIR}/qbittorrent-instances.tsv}"
SOURCE_COMMON_FILE="${QBT_SOURCE_COMMON_FILE:-${PROJECT_DIR}/qbittorrent-compose.common.yml}"
SOURCE_MANIFEST_FILE="${QBT_SOURCE_MANIFEST_FILE:-${PROJECT_DIR}/qbittorrent-instances.tsv}"
if [[ -r "${SCRIPT_DIR}/proton-qbittorrent-common.sh" ]]; then
	DEFAULT_QBT_COMMON_SCRIPT="${SCRIPT_DIR}/proton-qbittorrent-common.sh"
else
	DEFAULT_QBT_COMMON_SCRIPT="${PROJECT_DIR}/proton-qbittorrent-common.sh"
fi
QBT_COMMON_SCRIPT="${QBT_COMMON_SCRIPT:-$DEFAULT_QBT_COMMON_SCRIPT}"
CHECK_CONFIG=0
CHECK_RUNTIME=0
ERRORS=0

usage() {
	cat <<'EOF'
Usage: verify-qbittorrent-fleet.sh [--static-only | --config | --runtime]

  --static-only  Check the shared Compose policy, all five wrappers, each
                 project .env, and identical init hooks (default).
  --config       Also check root-owned per-instance Proton/qBittorrent env and
                 the one-key published-port artifact. Run as root.
  --runtime      Also require runtime state and Docker TCP/UDP/listen-port
                 agreement. Implies --config and is intended after recovery.
EOF
}

case "${1:---static-only}" in
--static-only) ;;
--config)
	CHECK_CONFIG=1
	;;
--runtime)
	CHECK_CONFIG=1
	CHECK_RUNTIME=1
	;;
--help | -h)
	usage
	exit 0
	;;
*)
	usage >&2
	exit 2
	;;
esac

pass() {
	printf 'PASS: %s\n' "$*"
}

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	ERRORS=$((ERRORS + 1))
}

assignment_count() {
	awk '/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/ { count++ } END { print count + 0 }' "$1" 2>/dev/null
}

env_value() {
	local file="$1"
	local key="$2"

	awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file" 2>/dev/null
}

require_env_value() {
	local file="$1"
	local key="$2"
	local expected="$3"
	local actual=""

	actual="$(env_value "$file" "$key")"
	if [[ "$actual" != "$expected" ]]; then
		fail "$file: expected $key=$expected, found ${actual:-<missing>}"
	fi
}

valid_port() {
	local port="$1"
	[[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

runtime_qbt_listen_port() {
	local qbt_env="$1"

	(
		local cookie_jar=""
		set -a
		# shellcheck disable=SC1090
		source "$qbt_env"
		set +a
		# shellcheck disable=SC1090
		source "$QBT_COMMON_SCRIPT"
		cookie_jar="$(mktemp)"
		trap 'rm -f "$cookie_jar"' EXIT
		qbt_login "$cookie_jar" >/dev/null 2>&1 || exit 1
		qbt_get_listen_port "$cookie_jar"
	)
}

if [[ ! -r "$MANIFEST_FILE" ]]; then
	fail "instance manifest is missing or unreadable: $MANIFEST_FILE"
fi
if [[ ! -r "$COMMON_COMPOSE_FILE" ]]; then
	fail "shared Compose policy is missing or unreadable: $COMMON_COMPOSE_FILE"
fi
if [[ -r "$SOURCE_COMMON_FILE" && -r "$COMMON_COMPOSE_FILE" ]]; then
	if cmp -s "$SOURCE_COMMON_FILE" "$COMMON_COMPOSE_FILE"; then
		pass "deployed shared Compose policy matches repository source"
	else
		fail "$COMMON_COMPOSE_FILE differs from $SOURCE_COMMON_FILE"
	fi
fi
if [[ -r "$SOURCE_MANIFEST_FILE" && -r "$MANIFEST_FILE" ]]; then
	if cmp -s "$SOURCE_MANIFEST_FILE" "$MANIFEST_FILE"; then
		pass "deployed instance manifest matches repository source"
	else
		fail "$MANIFEST_FILE differs from $SOURCE_MANIFEST_FILE"
	fi
fi

reference_init=""
instance_count=0

while IFS=$'\t' read -r instance webui _legacy_port bind_ip vpn_interface subnet vpn_table rule_priority; do
	[[ -n "$instance" && "$instance" != \#* ]] || continue
	instance_count=$((instance_count + 1))

	project_dir="${COMPOSE_ROOT}/qbittorrent-${instance}"
	compose_file="${project_dir}/docker-compose.yml"
	project_env="${project_dir}/.env"
	init_file="${project_dir}/custom-cont-init.d/10-clear-stale-qbittorrent-runtime"
	service="qbittorrent-${instance}"

	if [[ ! -r "$compose_file" ]]; then
		fail "$instance: missing Compose wrapper $compose_file"
		continue
	fi
	if [[ ! -r "$project_env" ]]; then
		fail "$instance: missing project env $project_env"
	else
		if [[ "$(assignment_count "$project_env")" != 1 ]]; then
			fail "$project_env must contain exactly one assignment"
		fi
		require_env_value "$project_env" QBT_HOST_BIND_IP "$bind_ip"
		if grep -Eq '^[[:space:]]*QBT_(PUBLISHED|FORWARDED)_PORT=' "$project_env"; then
			fail "$project_env must never contain a dynamic torrent port"
		fi
	fi

	grep -Fq "  ${service}:" "$compose_file" || fail "$instance: service key must be $service"
	grep -Fq "container_name: ${service}" "$compose_file" || fail "$instance: container_name must be $service"
	grep -Fq 'file: ../qbittorrent-common/docker-compose.common.yml' "$compose_file" || fail "$instance: wrapper does not extend the shared Compose policy"
	grep -Fq 'service: qbittorrent-common' "$compose_file" || fail "$instance: wrapper extends the wrong base service"
	grep -Fq "WEBUI_PORT: \"${webui}\"" "$compose_file" || fail "$instance: Web UI port must be $webui"
	# shellcheck disable=SC2016
	grep -Fq 'TORRENTING_PORT: "${QBT_PUBLISHED_PORT:?QBT_PUBLISHED_PORT must be supplied by Proton sync}"' "$compose_file" || fail "$instance: TORRENTING_PORT must require an explicitly injected Proton port"
	# shellcheck disable=SC2016
	grep -Fq '${QBT_HOST_BIND_IP:?QBT_HOST_BIND_IP must be set}' "$compose_file" || fail "$instance: torrent mapping must require its tunnel bind IP"
	if grep -Fq 'QBT_HOST_BIND_IP:-0.0.0.0' "$compose_file" || grep -Fq 'QBT_PUBLISHED_PORT:-' "$compose_file"; then
		fail "$instance: wrapper contains an unsafe bind-IP or torrent-port fallback"
	fi

	if grep -Eq '^[[:space:]]+(image:|restart:|stop_grace_period:|healthcheck:)' "$compose_file"; then
		fail "$instance: fleet-controlled service policy was duplicated into its wrapper"
	fi

	if command -v docker >/dev/null 2>&1; then
		if ! QBT_PUBLISHED_PORT=45678 docker compose -f "$compose_file" config --quiet >/dev/null 2>&1; then
			fail "$instance: Docker Compose could not resolve the wrapper"
		else
			resolved="$(QBT_PUBLISHED_PORT=45678 docker compose -f "$compose_file" config 2>/dev/null || true)"
			grep -Fq 'TORRENTING_PORT: "45678"' <<<"$resolved" || fail "$instance: injected port does not reach TORRENTING_PORT"
			[[ "$(grep -Fc 'published: "45678"' <<<"$resolved")" -eq 2 ]] || fail "$instance: injected port is not published once for both TCP and UDP"
			[[ "$(grep -Fc 'target: 45678' <<<"$resolved")" -eq 2 ]] || fail "$instance: TCP/UDP container targets do not both use the injected port"
			grep -Fq "host_ip: $bind_ip" <<<"$resolved" || fail "$instance: torrent port is not bound to $bind_ip"
		fi
	fi

	if [[ ! -r "$init_file" ]]; then
		fail "$instance: missing common init hook $init_file"
	elif [[ -z "$reference_init" ]]; then
		reference_init="$init_file"
	elif ! cmp -s "$reference_init" "$init_file"; then
		fail "$instance: init hook differs from $reference_init"
	fi

	if ((CHECK_CONFIG)); then
		proton_env="${PROTON_INSTANCE_ROOT}/${instance}/proton.env"
		qbt_env="${PROTON_INSTANCE_ROOT}/${instance}/qbittorrent.env"
		port_env="${PROTON_INSTANCE_ROOT}/${instance}/qbittorrent-port.env"

		for protected_file in "$proton_env" "$qbt_env" "$port_env"; do
			if [[ ! -r "$protected_file" ]]; then
				fail "$instance: root-owned config is missing or unreadable: $protected_file (run as root)"
			fi
		done

		if [[ -r "$proton_env" ]]; then
			require_env_value "$proton_env" INSTANCE_NAME "$instance"
			require_env_value "$proton_env" VPN_INTERFACE "$vpn_interface"
			require_env_value "$proton_env" WG_ADDRESS_SUBNET "$subnet"
			require_env_value "$proton_env" VPN_TABLE "$vpn_table"
			require_env_value "$proton_env" QBT_VPN_RULE_PRIORITY "$rule_priority"
		fi

		if [[ -r "$qbt_env" ]]; then
			require_env_value "$qbt_env" QBT_INSTANCE_NAME "$instance"
			require_env_value "$qbt_env" QBT_CONTAINER_NAME "$service"
			require_env_value "$qbt_env" QBT_COMPOSE_PROJECT_DIR "$project_dir"
			require_env_value "$qbt_env" QBT_COMPOSE_SERVICE "$service"
			require_env_value "$qbt_env" QBT_PORT_APPLY_MODE compose-recreate
			require_env_value "$qbt_env" QBT_PORT_ENV_FILE "$port_env"
			require_env_value "$qbt_env" QBT_NETWORK_NAME starr_network
			qbt_url="$(env_value "$qbt_env" QBITTORRENT_URL)"
			[[ "$qbt_url" == *":${webui}" || "$qbt_url" == *":${webui}/" ]] || fail "$instance: QBITTORRENT_URL must use Web UI port $webui"
			if grep -Eq '^[[:space:]]*QBT_(PUBLISHED|FORWARDED)_PORT=' "$qbt_env"; then
				fail "$qbt_env must not contain dynamic port values"
			fi
		fi

		published_port=""
		if [[ -r "$port_env" ]]; then
			if [[ "$(assignment_count "$port_env")" != 1 ]]; then
				fail "$port_env must contain exactly one assignment"
			fi
			published_port="$(env_value "$port_env" QBT_PUBLISHED_PORT)"
			valid_port "$published_port" || fail "$port_env has invalid QBT_PUBLISHED_PORT=${published_port:-<missing>}"
			grep -Fq 'QBT_FORWARDED_PORT=' "$port_env" && fail "$port_env contains obsolete QBT_FORWARDED_PORT"
		fi

		if ((CHECK_RUNTIME)) && [[ -n "$published_port" ]]; then
			state_file="${RUNTIME_ROOT}/${instance}/proton-port.state"
			if [[ ! -r "$state_file" ]]; then
				fail "$instance: runtime state is missing or unreadable: $state_file"
			else
				state_port="$(env_value "$state_file" CURRENT_PORT)"
				state_ip="$(env_value "$state_file" CURRENT_IP)"
				[[ "$state_port" == "$published_port" ]] || fail "$instance: runtime port $state_port differs from artifact $published_port"
				[[ "$state_ip" == "$bind_ip" ]] || fail "$instance: runtime tunnel IP ${state_ip:-<missing>} differs from bind IP $bind_ip"
			fi

			if ! docker inspect "$service" >/dev/null 2>&1; then
				fail "$instance: Docker container $service is absent"
			else
				container_status="$(docker inspect -f '{{.State.Status}}' "$service" 2>/dev/null || true)"
				health_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$service" 2>/dev/null || true)"
				[[ "$container_status" == running ]] || fail "$instance: container status is $container_status"
				[[ "$health_status" == healthy ]] || fail "$instance: container health is $health_status"

				container_port="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$service" 2>/dev/null | awk -F= '$1 == "TORRENTING_PORT" { print $2; exit }')"
				[[ "$container_port" == "$published_port" ]] || fail "$instance: container TORRENTING_PORT=$container_port differs from artifact $published_port"

				bindings="$(docker inspect -f '{{range $port, $items := .HostConfig.PortBindings}}{{range $items}}{{printf "%s %s:%s\n" $port .HostIp .HostPort}}{{end}}{{end}}' "$service" 2>/dev/null || true)"
				[[ "$(grep -Fc "${published_port}/tcp ${bind_ip}:${published_port}" <<<"$bindings")" -eq 1 ]] || fail "$instance: expected exactly one TCP bind ${bind_ip}:${published_port}"
				[[ "$(grep -Fc "${published_port}/udp ${bind_ip}:${published_port}" <<<"$bindings")" -eq 1 ]] || fail "$instance: expected exactly one UDP bind ${bind_ip}:${published_port}"
				[[ "$(grep -Ec "^${published_port}/(tcp|udp) " <<<"$bindings")" -eq 2 ]] || fail "$instance: torrent port has an unexpected extra or missing Docker binding"

				container_source_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "starr_network"}}{{.IPAddress}}{{end}}' "$service" 2>/dev/null || true)"
				if [[ -z "$container_source_ip" ]]; then
					fail "$instance: could not resolve the container IPv4 address on starr_network"
				elif ! ip -4 rule show 2>/dev/null | awk -v source="$container_source_ip" -v table="$vpn_table" '
					{
						from_match = 0
						table_match = 0
						for (i = 1; i <= NF; i++) {
							if ($i == "from" && i < NF) {
								candidate = $(i + 1)
								sub(/\/32$/, "", candidate)
								if (candidate == source) from_match = 1
							}
							if (($i == "lookup" || $i == "table") && i < NF && $(i + 1) == table) table_match = 1
						}
						if (from_match && table_match) found = 1
					}
					END { exit found ? 0 : 1 }
				'; then
					fail "$instance: source $container_source_ip does not have a policy rule to VPN table $vpn_table"
				fi
			fi

			qbt_config="${project_dir}/config/qBittorrent/qBittorrent.conf"
			if [[ -r "$qbt_config" ]]; then
				configured_port="$(awk -F= '$1 == "Session\\Port" { print $2; exit }' "$qbt_config")"
				[[ "$configured_port" == "$published_port" ]] || fail "$instance: qBittorrent Session\\Port=$configured_port differs from artifact $published_port"
			fi

			if [[ ! -r "$QBT_COMMON_SCRIPT" ]]; then
				fail "$instance: qBittorrent API helper is missing or unreadable: $QBT_COMMON_SCRIPT"
			else
				api_port=""
				if api_port="$(runtime_qbt_listen_port "$qbt_env")"; then
					[[ "$api_port" == "$published_port" ]] || fail "$instance: qBittorrent API listen_port=$api_port differs from artifact $published_port"
				else
					fail "$instance: could not authenticate to qBittorrent API for runtime listen-port verification"
				fi
			fi
		fi
	fi

	pass "$instance fleet contract"
done <"$MANIFEST_FILE"

if [[ "$instance_count" -ne 5 ]]; then
	fail "manifest must define exactly five instances; found $instance_count"
fi

if ((ERRORS > 0)); then
	printf '\nFleet verification failed with %d error(s).\n' "$ERRORS" >&2
	exit 1
fi

printf '\nFleet verification passed for all %d qBittorrent instances.\n' "$instance_count"
