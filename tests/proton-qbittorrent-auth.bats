#!/usr/bin/env bats

setup() {
  TEST_TMPDIR="${BATS_TEST_TMPDIR:-$BATS_TMPDIR}"
  TMPBIN="$TEST_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export PATH="$TMPBIN:$PATH"
  export CURL_ARGS="$TEST_TMPDIR/curl-args.log"

  cat > "$TMPBIN/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  printf '%s\n' "$arg" >> "$CURL_ARGS"
done
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
  *)
    echo 'Ok.'
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

@test "qbt_wait_for_webui treats 403 as reachable" {
  run env QBT_TEST_VERSION_STATUS=403 bash -c 'source ./proton-qbittorrent-common.sh; QBITTORRENT_URL=http://127.0.0.1:8081; qbt_wait_for_webui 1 0'
  [ "$status" -eq 0 ]
}

@test "qbt_wait_for_webui fails on 500 responses" {
  run env QBT_TEST_VERSION_STATUS=500 bash -c 'source ./proton-qbittorrent-common.sh; QBITTORRENT_URL=http://127.0.0.1:8081; qbt_wait_for_webui 1 0'
  [ "$status" -ne 0 ]
}
