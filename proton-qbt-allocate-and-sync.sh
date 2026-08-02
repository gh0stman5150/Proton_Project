#!/usr/bin/env bash
set -euo pipefail

INSTANCE="${1:-}"
if [[ -z "$INSTANCE" ]]; then
	echo "Usage: ${0##*/} INSTANCE" >&2
	exit 2
fi

LOCK_FILE="/run/proton/port-alloc.lock"

ensure_directory() {
	local dir="${1:-}"
	[[ -d "$dir" ]] || mkdir -p "$dir"
}

ensure_directory "/run/proton"

# Acquire global allocation lock; block until available so callers can queue
exec 201>"$LOCK_FILE"
flock 201

# Start the per-instance port-forward service (it will request/refresh NAT-PMP)
systemctl start proton-port-forward@"$INSTANCE" || true

# Wait for the per-instance state file to appear
STATE_FILE="/run/proton/$INSTANCE/proton-port.state"
WAIT_TRIES="${WAIT_TRIES:-40}"
for i in $(seq 1 "$WAIT_TRIES"); do
	if [[ -f "$STATE_FILE" ]]; then
		break
	fi
	sleep 3
done

if [[ ! -f "$STATE_FILE" ]]; then
	echo "ERROR: state file not present for $INSTANCE after waiting" >&2
	echo "--- unit status for proton-port-forward@${INSTANCE}.service ---"
	systemctl status proton-port-forward@"${INSTANCE}" --no-pager || true
	echo "--- recent journal for proton-port-forward@${INSTANCE}.service (last 200 lines) ---"
	journalctl -u proton-port-forward@"${INSTANCE}" -n 200 --no-pager -o cat || true
	exit 1
fi

# Run the sync (this script will do its own locking for qB syncs)
/usr/local/bin/proton_project/proton-qbittorrent-sync-safe.sh "$INSTANCE"

# Release lock implicitly on exit
exit 0
