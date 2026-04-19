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

QBT_LOGIN_ERROR=""
QBT_LOGIN_HTTP_STATUS=""

qbt_login() {
    local cookie_jar="$1"
    local login_body
    local http_status curl_exit curl_error
    local response_file error_file

    : "${QBITTORRENT_URL:?Missing QBITTORRENT_URL}"
    : "${QBITTORRENT_USER:?Missing QBITTORRENT_USER}"
    : "${QBITTORRENT_PASS:?Missing QBITTORRENT_PASS}"

    QBT_LOGIN_ERROR=""
    QBT_LOGIN_HTTP_STATUS=""

    : > "$cookie_jar"
    response_file="$(mktemp)"
    error_file="$(mktemp)"

    http_status="$(curl -sS \
        -o "$response_file" \
        -w '%{http_code}' \
        -c "$cookie_jar" \
        --data-urlencode "username=$QBITTORRENT_USER" \
        --data-urlencode "password=$QBITTORRENT_PASS" \
        "$QBITTORRENT_URL/api/v2/auth/login" 2>"$error_file")"
    curl_exit=$?
    login_body="$(cat "$response_file" 2>/dev/null || true)"

    rm -f "$response_file"

    if [[ "$curl_exit" -ne 0 ]]; then
        curl_error="$(tr '\n' ' ' < "$error_file")"
        rm -f "$error_file"
        if [[ -n "$curl_error" ]]; then
            QBT_LOGIN_ERROR="qBittorrent Web UI unreachable at $QBITTORRENT_URL (${curl_error})"
        else
            QBT_LOGIN_ERROR="qBittorrent Web UI unreachable at $QBITTORRENT_URL (curl exit $curl_exit)"
        fi
        return 1
    fi

    rm -f "$error_file"
    QBT_LOGIN_HTTP_STATUS="${http_status:-000}"

    if [[ "$login_body" != "Ok." ]]; then
        if [[ -n "$login_body" ]]; then
            QBT_LOGIN_ERROR="qBittorrent rejected login at $QBITTORRENT_URL (HTTP ${QBT_LOGIN_HTTP_STATUS}: ${login_body})"
        else
            QBT_LOGIN_ERROR="qBittorrent rejected login at $QBITTORRENT_URL (HTTP ${QBT_LOGIN_HTTP_STATUS})"
        fi
        return 1
    fi

    return 0
}

qbt_get_listen_port() {
    local cookie_jar="$1"

    curl -fsS -b "$cookie_jar" \
        "$QBITTORRENT_URL/api/v2/app/preferences" \
        | tr ',{}' '\n' \
        | awk -F: '/"listen_port"/ {gsub(/[^0-9]/, "", $2); print $2; exit}'
}

qbt_webui_http_status() {
    local max_time="${1:-5}"

    curl -sS -o /dev/null -w '%{http_code}' --max-time "$max_time" \
        "$QBITTORRENT_URL/api/v2/app/version" || true
}

qbt_webui_reachable() {
    local max_time="${1:-5}"
    local http_status

    http_status="$(qbt_webui_http_status "$max_time")"

    case "$http_status" in
        200|204|301|302|303|307|308|401|403)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

qbt_wait_for_webui() {
    local max_attempts="${1:-12}"
    local sleep_seconds="${2:-5}"
    local attempt

    : "${QBITTORRENT_URL:?Missing QBITTORRENT_URL}"

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if qbt_webui_reachable 5; then
            return 0
        fi
        sleep "$sleep_seconds"
    done

    return 1
}
