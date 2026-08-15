#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${QBT_INSTANCE_MANIFEST:-/opt/qbittorrent-common/qbittorrent-instances.tsv}"
VERIFY_SCRIPT="${QBT_FLEET_VERIFY_SCRIPT:-${SCRIPT_DIR}/verify-qbittorrent-fleet.sh}"
SYNC_SCRIPT="${QBT_SYNC_SCRIPT:-/usr/local/bin/proton/proton-qbittorrent-sync-safe.sh}"
HEALTH_TRIES="${QBT_FLEET_HEALTH_TRIES:-12}"
HEALTH_DELAY="${QBT_FLEET_HEALTH_DELAY:-5}"

usage() {
	cat <<'EOF'
Usage: reconcile-qbittorrent-fleet.sh --preflight|--check|--recreate

  --preflight  Validate static and root-owned configuration without mutation.
  --check      Validate configuration plus current Docker/runtime port parity.
  --recreate   Preflight every instance, refuse the entire rollout if any
               container is wedged, then recreate all five sequentially with
               each instance's own active Proton port and health-gate each one.

A Proton lease change should not use this tool; the per-instance port-forward
service recreates only the instance that owns that lease. Use --recreate for a
fleet-wide Compose/image/init/shared-setting change.
EOF
}

mode="${1:-}"
case "$mode" in
--preflight | --check | --recreate) ;;
--help | -h)
	usage
	exit 0
	;;
*)
	usage >&2
	exit 2
	;;
esac

if [[ ! -x "$VERIFY_SCRIPT" ]]; then
	echo "ERROR: Fleet verifier is not executable: $VERIFY_SCRIPT" >&2
	exit 1
fi

case "$mode" in
--preflight)
	exec "$VERIFY_SCRIPT" --config
	;;
--check)
	exec "$VERIFY_SCRIPT" --runtime
	;;
esac

if ((EUID != 0)); then
	echo "ERROR: --recreate must run as root so protected instance config and runtime state can be validated." >&2
	exit 1
fi
if [[ ! -x "$SYNC_SCRIPT" ]]; then
	echo "ERROR: Installed qBittorrent sync script is not executable: $SYNC_SCRIPT" >&2
	exit 1
fi
if [[ ! -r "$MANIFEST_FILE" ]]; then
	echo "ERROR: Instance manifest is missing or unreadable: $MANIFEST_FILE" >&2
	exit 1
fi
if [[ ! "$HEALTH_TRIES" =~ ^[0-9]+$ ]] || ((HEALTH_TRIES < 1)); then
	echo "ERROR: QBT_FLEET_HEALTH_TRIES must be a positive integer." >&2
	exit 2
fi
if [[ ! "$HEALTH_DELAY" =~ ^[0-9]+$ ]]; then
	echo "ERROR: QBT_FLEET_HEALTH_DELAY must be a non-negative integer." >&2
	exit 2
fi

"$VERIFY_SCRIPT" --config

instances=()
while IFS=$'\t' read -r instance _; do
	[[ -n "$instance" && "$instance" != \#* ]] || continue
	instances+=("$instance")
done <"$MANIFEST_FILE"

# Refuse before changing the first service if any fleet member is already in a
# state that normal Compose recreation cannot repair. This prevents a partial
# structural rollout and avoids repeating the Sonarr kernel/CIFS wedge.
for instance in "${instances[@]}"; do
	container="qbittorrent-${instance}"
	if ! docker inspect "$container" >/dev/null 2>&1; then
		echo "ERROR: $container is absent; refusing fleet recreation." >&2
		exit 1
	fi
	container_status="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
	container_health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
	if [[ "$container_status" != running || "$container_health" != healthy ]]; then
		echo "ERROR: $container is not a healthy running baseline (status=$container_status health=$container_health); refusing fleet recreation." >&2
		exit 1
	fi
	if docker top "$container" -eo pid,stat,cmd 2>/dev/null |
		awk 'NR > 1 && $2 ~ /^Z/ { found = 1 } END { exit found ? 0 : 1 }'; then
		echo "ERROR: $container contains a zombie process; refusing the entire fleet recreation." >&2
		exit 1
	fi
	if docker top "$container" -eLo pid,stat,wchan:48,cmd 2>/dev/null |
		awk 'NR > 1 && $2 ~ /^D/ { found = 1 } END { exit found ? 0 : 1 }'; then
		echo "ERROR: $container has an uninterruptible D-state task; a host-level recovery is required before fleet recreation." >&2
		exit 1
	fi
done

for instance in "${instances[@]}"; do
	container="qbittorrent-${instance}"
	echo "=== Recreating $container with its own active Proton port ==="
	QBT_FORCE_RECREATE=1 "$SYNC_SCRIPT" "$instance"

	health=""
	for ((attempt = 1; attempt <= HEALTH_TRIES; attempt++)); do
		health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || true)"
		[[ "$health" == healthy ]] && break
		sleep "$HEALTH_DELAY"
	done
	if [[ "$health" != healthy ]]; then
		echo "ERROR: $container did not become healthy; stopping the rolling fleet change before the next instance." >&2
		exit 1
	fi
done

"$VERIFY_SCRIPT" --runtime
echo "All qBittorrent instances were recreated sequentially and passed runtime parity checks."
