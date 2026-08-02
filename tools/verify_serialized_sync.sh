#!/usr/bin/env bash
set -euo pipefail

# Verification script: run serialized allocation+sync for each instance
# and validate /run/proton state, host port bindings, docker published ports,
# and published-port env file.

INSTANCES=(lidarr prowlarr radarr sonarr whisparr)
ALLOC_SCRIPT="/usr/local/bin/proton_project/proton-qbt-allocate-and-sync.sh"
STATE_DIR="/run/proton"
VERIFY_TIMEOUT="600" # seconds per instance

ELEVATE=""
if ((EUID != 0)); then
	ELEVATE="sudo"
fi

echo "Verifier running (elevate: ${ELEVATE:-none})"

if [[ ! -f "$ALLOC_SCRIPT" ]]; then
	echo "ERROR: allocator script not found at $ALLOC_SCRIPT" >&2
	exit 2
fi

if [[ ! -x "$ALLOC_SCRIPT" ]]; then
	echo "Making allocator executable"
	$ELEVATE chmod +x "$ALLOC_SCRIPT" || true
fi

FAIL_COUNT=0
declare -A STATUS

for inst in "${INSTANCES[@]}"; do
	echo
	echo "=== INSTANCE: $inst ==="

	# Run allocator (will start port-forward and run sync). It blocks until done.
	if $ELEVATE timeout "$VERIFY_TIMEOUT" "$ALLOC_SCRIPT" "$inst"; then
		echo "Allocator finished for $inst"
	else
		rc=$?
		echo "ERROR: allocator failed for $inst (exit $rc)" >&2
		echo "--- unit status for proton-port-forward@${inst}.service ---"
		$ELEVATE systemctl status proton-port-forward@"${inst}" --no-pager || true
		echo "--- recent journal for proton-port-forward@${inst}.service (last 200 lines) ---"
		$ELEVATE journalctl -u proton-port-forward@"${inst}" -n 200 --no-pager -o cat || true
		STATUS["$inst"]="allocator-failed"
		FAIL_COUNT=$((FAIL_COUNT + 1))
		continue
	fi

	state_file="${STATE_DIR}/${inst}/proton-port.state"
	for i in $(seq 1 20); do
		if [[ -f "$state_file" ]]; then
			break
		fi
		sleep 1
	done

	if [[ ! -f "$state_file" ]]; then
		echo "ERROR: state file missing for $inst" >&2
		STATUS["$inst"]="no-state-file"
		FAIL_COUNT=$((FAIL_COUNT + 1))
		continue
	fi

	PORT="$($ELEVATE awk -F= '/^CURRENT_PORT=/ {print $2; exit}' "$state_file" 2>/dev/null || echo "")"
	IP="$($ELEVATE awk -F= '/^CURRENT_IP=/ {print $2; exit}' "$state_file" 2>/dev/null || echo "")"
	echo "STATE: PORT=${PORT:-(empty)} IP=${IP:-(empty)}"

	if [[ -z "$PORT" ]]; then
		echo "ERROR: no CURRENT_PORT in $state_file" >&2
		STATUS["$inst"]="no-port-in-state"
		FAIL_COUNT=$((FAIL_COUNT + 1))
		continue
	fi

	# Check host TCP/UDP listens
	tcp_listen="$($ELEVATE ss -ltnp 2>/dev/null | awk '{print $4}' | grep -E "[:\.]$PORT$" || true)"
	udp_listen="$($ELEVATE ss -lunp 2>/dev/null | awk '{print $4}' | grep -E "[:\.]$PORT$" || true)"
	if [[ -n "$tcp_listen" || -n "$udp_listen" ]]; then
		echo "Host listens:"
		[[ -n "$tcp_listen" ]] && echo "  TCP: $tcp_listen"
		[[ -n "$udp_listen" ]] && echo "  UDP: $udp_listen"
	else
		echo "Warning: no host TCP/UDP listen found for $PORT"
	fi

	# Find any docker container publishing this host port
	docker_pub="$($ELEVATE docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E ":$PORT\b" || true)"
	if [[ -n "$docker_pub" ]]; then
		echo "Docker published port owner(s):"
		echo "$docker_pub"
	else
		echo "Warning: no docker container publishing host port $PORT"
	fi

	# Determine QBT port env file from instance qbittorrent.env
	inst_qb_env="/etc/proton/instances/$inst/qbittorrent.env"
	qbt_port_env="/etc/proton/qbittorrent-port.env"
	if [[ -f "$inst_qb_env" ]]; then
		val="$($ELEVATE awk -F= '/^QBT_PORT_ENV_FILE=/ {print $2; exit}' "$inst_qb_env" 2>/dev/null || echo "")"
		if [[ -n "$val" ]]; then
			qbt_port_env="$val"
		fi
	fi

	if [[ -f "$qbt_port_env" ]]; then
		pub="$($ELEVATE awk -F= '/^QBT_PUBLISHED_PORT=/ {print $2; exit}' "$qbt_port_env" 2>/dev/null || echo "")"
		echo "$qbt_port_env: QBT_PUBLISHED_PORT=${pub:-(empty)}"
		if [[ "$pub" == "$PORT" ]]; then
			STATUS["$inst"]="ok"
		else
			STATUS["$inst"]="mismatch-published-port"
			FAIL_COUNT=$((FAIL_COUNT + 1))
		fi
	else
		echo "ERROR: published-port env file not found: $qbt_port_env" >&2
		STATUS["$inst"]="no-port-env-file"
		FAIL_COUNT=$((FAIL_COUNT + 1))
	fi
done

echo
echo "=== VERIFICATION SUMMARY ==="
for inst in "${INSTANCES[@]}"; do
	printf '%-10s %s\n' "$inst" "${STATUS[$inst]:-unknown}"
done

if ((FAIL_COUNT > 0)); then
	echo "FAIL: ${FAIL_COUNT} instance(s) failed verification"
	exit 2
else
	echo "OK: all instances verified"
	exit 0
fi
