#!/usr/bin/env bash
set -euo pipefail

NAS_HOST="${NAS_HOST:-192.168.237.140}"
NAS_PORT="${NAS_PORT:-445}"
NAS_WAIT_SECONDS="${NAS_WAIT_SECONDS:-60}"

if ! [[ "$NAS_PORT" =~ ^[0-9]+$ ]] || ((NAS_PORT < 1 || NAS_PORT > 65535)); then
	echo "ERROR: NAS_PORT must be between 1 and 65535" >&2
	exit 2
fi

if ! [[ "$NAS_WAIT_SECONDS" =~ ^[0-9]+$ ]] || ((NAS_WAIT_SECONDS < 1)); then
	echo "ERROR: NAS_WAIT_SECONDS must be a positive integer" >&2
	exit 2
fi

deadline=$((SECONDS + NAS_WAIT_SECONDS))
while ((SECONDS < deadline)); do
	if ip route get "$NAS_HOST" >/dev/null 2>&1 && nc -z -w 2 "$NAS_HOST" "$NAS_PORT" >/dev/null 2>&1; then
		echo "NAS SMB endpoint ${NAS_HOST}:${NAS_PORT} is reachable"
		exit 0
	fi
	sleep 1
done

echo "ERROR: NAS SMB endpoint ${NAS_HOST}:${NAS_PORT} was not reachable within ${NAS_WAIT_SECONDS} seconds" >&2
exit 1