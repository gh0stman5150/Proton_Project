#!/bin/bash

set -euo pipefail

QBITTORRENT_URL="${QBITTORRENT_URL:-http://localhost:8081}"

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' is not installed." >&2
        exit 1
    fi
}

for cmd in natpmpc docker curl; do
    require_command "$cmd"
done

if ! docker inspect -f '{{.State.Status}}' qbittorrent >/dev/null 2>&1; then
    echo "ERROR: qBittorrent container 'qbittorrent' is not present." >&2
    exit 1
fi

if ! curl -fsS --max-time 5 "$QBITTORRENT_URL/api/v2/app/version" >/dev/null; then
    echo "ERROR: qBittorrent Web API is not reachable at $QBITTORRENT_URL." >&2
    exit 1
fi

exit 0
