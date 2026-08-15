#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_COMMON_SCRIPT="${PROTON_INSTANCE_COMMON_SCRIPT:-${SCRIPT_DIR}/proton-instance-common.sh}"
if [[ ! -f "$INSTANCE_COMMON_SCRIPT" ]]; then
	echo "ERROR: Proton instance helper not found: $INSTANCE_COMMON_SCRIPT" >&2
	exit 2
fi
# shellcheck disable=SC1090
source "$INSTANCE_COMMON_SCRIPT"
proton_instance_init "${1:-}"

LOCK_FILE="${QBT_ALLOC_LOCK_FILE:-${STATE_DIR}/qbt-allocate.lock}"
QBITTORRENT_SYNC_SCRIPT="${QBITTORRENT_SYNC_SCRIPT:-/usr/local/bin/proton/proton-qbittorrent-sync-safe.sh}"
WAIT_TRIES="${WAIT_TRIES:-40}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-3}"

for cmd in flock journalctl mkdir sleep systemctl; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "ERROR: Required command '$cmd' is not installed." >&2
		exit 1
	fi
done

if [[ ! "$WAIT_TRIES" =~ ^[0-9]+$ ]] || ((WAIT_TRIES < 1)); then
	echo "ERROR: WAIT_TRIES must be a positive integer." >&2
	exit 2
fi
if [[ ! "$WAIT_INTERVAL_SECONDS" =~ ^[0-9]+$ ]]; then
	echo "ERROR: WAIT_INTERVAL_SECONDS must be a non-negative integer." >&2
	exit 2
fi
if [[ ! -x "$QBITTORRENT_SYNC_SCRIPT" ]]; then
	echo "ERROR: qBittorrent sync script is not executable: $QBITTORRENT_SYNC_SCRIPT" >&2
	exit 1
fi

ensure_directory() {
	local dir="${1:-}"
	[[ -d "$dir" ]] || mkdir -p "$dir"
}

ensure_directory "${LOCK_FILE%/*}"

# Coalesce duplicate callers for this instance without blocking unrelated
# Proton tunnels. Each tunnel has its own NAT-PMP gateway and lease.
exec 201>"$LOCK_FILE"
flock 201

# Start the per-instance port-forward service (it will request/refresh NAT-PMP)
systemctl start "proton-port-forward@${INSTANCE}.service" || true

# Wait for the per-instance state file to appear
for ((wait_try = 0; wait_try < WAIT_TRIES; wait_try++)); do
	if [[ -f "$STATE_FILE" ]]; then
		break
	fi
	sleep "$WAIT_INTERVAL_SECONDS"
done

if [[ ! -f "$STATE_FILE" ]]; then
	echo "ERROR: state file not present for $INSTANCE after waiting" >&2
	echo "--- unit status for proton-port-forward@${INSTANCE}.service ---"
	systemctl status "proton-port-forward@${INSTANCE}.service" --no-pager || true
	echo "--- recent journal for proton-port-forward@${INSTANCE}.service (last 200 lines) ---"
	journalctl -u "proton-port-forward@${INSTANCE}.service" -n 200 --no-pager -o cat || true
	exit 1
fi

# Run the sync (this script will do its own locking for qB syncs)
"$QBITTORRENT_SYNC_SCRIPT" "$INSTANCE"

# Release lock implicitly on exit
exit 0
