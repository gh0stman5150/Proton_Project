#!/usr/bin/env bats

setup() {
  TMPBIN="$BATS_TMPDIR/bin"
  mkdir -p "$TMPBIN"
  export PATH="$TMPBIN:$PATH"
  export CURL_ARGS="$BATS_TMPDIR/curl-args.log"

  cat > "$TMPBIN/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  printf '%s\n' "$arg" >> "$CURL_ARGS"
done
echo 'Ok.'
EOF
  chmod +x "$TMPBIN/curl"
}

@test "qbt_login uses data-urlencode so special-character credentials stay intact" {
  run bash -c 'source ./proton-qbittorrent-common.sh; QBITTORRENT_URL=http://127.0.0.1:8081; QBITTORRENT_USER="user name"; QBITTORRENT_PASS="p@ss&= %"; qbt_login "$1"' _ "$BATS_TMPDIR/cookie.jar"
  [ "$status" -eq 0 ]
  grep -F -- '--data-urlencode' "$CURL_ARGS"
  grep -F 'username=user name' "$CURL_ARGS"
  grep -F 'password=p@ss&= %' "$CURL_ARGS"
}
