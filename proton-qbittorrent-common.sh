#!/usr/bin/env bash

qbt_source_env_file() {
    local env_file="$1"
    local env_mode env_owner

    if [[ ! -f "$env_file" ]]; then
        echo "ERROR: qBittorrent env file not found: $env_file." >&2
        return 1
    fi

    env_mode="$(stat -c '%a' "$env_file")"
    env_owner="$(stat -c '%u' "$env_file")"

    if [[ "$env_mode" != "600" ]]; then
        echo "ERROR: $env_file must have mode 600." >&2
        return 1
    fi

    if [[ "$env_owner" != "0" ]]; then
        echo "ERROR: $env_file must be owned by root." >&2
        return 1
    fi

    # shellcheck disable=SC1090
    source "$env_file"

    if [[ -n "${QBITTORRENT_URL:-}" ]]; then
        QBITTORRENT_URL="${QBITTORRENT_URL%/}"
        export QBITTORRENT_URL
    fi
}

qbt_login() {
    local cookie_jar="$1"
    local login_body

    : "${QBITTORRENT_URL:?Missing QBITTORRENT_URL}"
    : "${QBITTORRENT_USER:?Missing QBITTORRENT_USER}"
    : "${QBITTORRENT_PASS:?Missing QBITTORRENT_PASS}"

    : > "$cookie_jar"
    login_body="$(curl -fsS \
        -c "$cookie_jar" \
        --data-urlencode "username=$QBITTORRENT_USER" \
        --data-urlencode "password=$QBITTORRENT_PASS" \
        "$QBITTORRENT_URL/api/v2/auth/login" || true)"

    [[ "$login_body" == "Ok." ]]
}

qbt_get_listen_port() {
    local cookie_jar="$1"

    curl -fsS -b "$cookie_jar" \
        "$QBITTORRENT_URL/api/v2/app/preferences" \
        | tr ',{}' '\n' \
        | awk -F: '/"listen_port"/ {gsub(/[^0-9]/, "", $2); print $2; exit}'
}

qbt_wait_for_webui() {
    local max_attempts="${1:-12}"
    local sleep_seconds="${2:-5}"
    local attempt

    : "${QBITTORRENT_URL:?Missing QBITTORRENT_URL}"

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if curl -fsS --max-time 5 "$QBITTORRENT_URL/api/v2/app/version" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$sleep_seconds"
    done

    return 1
}
