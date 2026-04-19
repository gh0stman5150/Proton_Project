#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export PATH="$TMPBIN:$PATH"
  export CURL_ARGS="$TEST_TMPDIR/curl-args.log"

  cat > "$TMPBIN/curl" <<'EOF'
#!/usr/bin/env bash
output_file=""
for arg in "$@"; do
  printf '%s\n' "$arg" >> "$CURL_ARGS"
done
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "-o" ]]; then
    next_index=$((i + 1))
    output_file="${!next_index}"
  fi
done

write_body() {
  if [[ -n "$output_file" ]]; then
    printf '%s' "$1" > "$output_file"
  else
    printf '%s' "$1"
  fi
}

case "$*" in
  *'/api/v2/app/version'*)
    status="${QBT_TEST_VERSION_STATUS:-200}"
    if [[ "$*" == *'%{http_code}'* ]]; then
      printf '%s' "$status"
      exit 0
    fi
    case "$status" in
      200|204|301|302|303|307|308|401|403)
        exit 0
        ;;
      *)
        exit 22
        ;;
    esac
    ;;
  *'/api/v2/auth/login'*)
    if [[ -n "${QBT_TEST_LOGIN_CURL_EXIT:-}" ]]; then
      printf '%s\n' "${QBT_TEST_LOGIN_STDERR:-curl: (7) Failed to connect}" >&2
      exit "$QBT_TEST_LOGIN_CURL_EXIT"
    fi
    write_body "${QBT_TEST_LOGIN_BODY:-Ok.}"
    if [[ "$*" == *'%{http_code}'* ]]; then
      printf '%s' "${QBT_TEST_LOGIN_STATUS:-200}"
    fi
    ;;
  *)
    write_body 'Ok.'
    ;;
esac
EOF
  chmod +x "$TMPBIN/curl"
}

@test "qbt_login uses data-urlencode so special-character credentials stay intact" {
  COOKIE_JAR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/cookie.jar"
  run bash -c 'source ./proton-qbittorrent-common.sh; QBITTORRENT_URL=http://127.0.0.1:8081; QBITTORRENT_USER="user name"; QBITTORRENT_PASS="p@ss&= %"; qbt_login "$1"' _ "$COOKIE_JAR"
  [ "$status" -eq 0 ]
  grep -F -- '--data-urlencode' "$CURL_ARGS"
  grep -F 'username=user name' "$CURL_ARGS"
  grep -F 'password=p@ss&= %' "$CURL_ARGS"
}

@test "qbt_login reports an unreachable Web UI separately from bad credentials" {
  COOKIE_JAR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/cookie.jar"
  run env \
    QBT_TEST_LOGIN_CURL_EXIT=7 \
    QBT_TEST_LOGIN_STDERR='curl: (7) Failed to connect to 127.0.0.1 port 8081 after 0 ms: Could not connect to server' \
    bash -c 'source ./proton-qbittorrent-common.sh; QBITTORRENT_URL=http://127.0.0.1:8081; QBITTORRENT_USER=test-user; QBITTORRENT_PASS=test-pass; qbt_login "$1" || { printf "%s" "$QBT_LOGIN_ERROR"; exit 1; }' _ "$COOKIE_JAR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"qBittorrent Web UI unreachable at http://127.0.0.1:8081"* ]]
  [[ "$output" == *"Failed to connect to 127.0.0.1 port 8081"* ]]
}

@test "qbt_login reports rejected credentials separately from transport failures" {
  COOKIE_JAR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}/cookie.jar"
  run env \
    QBT_TEST_LOGIN_BODY='Fails.' \
    QBT_TEST_LOGIN_STATUS=403 \
    bash -c 'source ./proton-qbittorrent-common.sh; QBITTORRENT_URL=http://127.0.0.1:8081; QBITTORRENT_USER=test-user; QBITTORRENT_PASS=test-pass; qbt_login "$1" || { printf "%s" "$QBT_LOGIN_ERROR"; exit 1; }' _ "$COOKIE_JAR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"qBittorrent rejected login at http://127.0.0.1:8081"* ]]
  [[ "$output" == *"HTTP 403"* ]]
  [[ "$output" == *"Fails."* ]]
}

@test "qbt_wait_for_webui treats 403 as reachable" {
  run env QBT_TEST_VERSION_STATUS=403 bash -c 'source ./proton-qbittorrent-common.sh; QBITTORRENT_URL=http://127.0.0.1:8081; qbt_wait_for_webui 1 0'
  [ "$status" -eq 0 ]
}

@test "qbt_wait_for_webui fails on 500 responses" {
  run env QBT_TEST_VERSION_STATUS=500 bash -c 'source ./proton-qbittorrent-common.sh; QBITTORRENT_URL=http://127.0.0.1:8081; qbt_wait_for_webui 1 0'
  [ "$status" -ne 0 ]
}
