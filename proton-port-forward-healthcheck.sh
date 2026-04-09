#!/usr/bin/env bash

set -euo pipefail

QBITTORRENT_ENV_FILE="${QBITTORRENT_ENV_FILE:-/etc/proton/qbittorrent.env}"

require_command() {
	local cmd="$1"

	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "ERROR: Required command '$cmd' is not installed." >&2
		exit 1
	fi
}

for cmd in curl ip natpmpc stat systemd-cat; do
	require_command "$cmd"
done

if [[ ! -f "$QBITTORRENT_ENV_FILE" ]]; then
	echo "ERROR: qBittorrent env file not found: $QBITTORRENT_ENV_FILE." >&2
	exit 1
fi

ENV_MODE="$(stat -c '%a' "$QBITTORRENT_ENV_FILE")"
ENV_OWNER="$(stat -c '%u' "$QBITTORRENT_ENV_FILE")"

if [[ "$ENV_MODE" != "600" ]]; then
	echo "ERROR: $QBITTORRENT_ENV_FILE must have mode 600." >&2
	exit 1
fi

if [[ "$ENV_OWNER" != "0" ]]; then
	echo "ERROR: $QBITTORRENT_ENV_FILE must be owned by root." >&2
	exit 1
fi

# The dedicated qBittorrent env file is authoritative for these scripts.
# This avoids stale manager/drop-in environment values overriding runtime config.
# shellcheck disable=SC1090
source "$QBITTORRENT_ENV_FILE"

: "${QBITTORRENT_URL:?QBITTORRENT_URL must be set in ${QBITTORRENT_ENV_FILE}}"
QBITTORRENT_URL="${QBITTORRENT_URL%/}"

HTTP_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
	"$QBITTORRENT_URL/api/v2/app/version" || true)"

case "$HTTP_STATUS" in
200 | 204 | 301 | 302 | 303 | 307 | 308 | 401 | 403)
	;;
*)
	echo "WARNING: qBittorrent Web API is not reachable at $QBITTORRENT_URL (HTTP ${HTTP_STATUS:-000}); continuing and relying on the sync loop to retry later." >&2
	;;
esac
