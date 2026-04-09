#!/bin/bash
# protonvpn-port-forward.sh

set -u
set -o pipefail

VPN_GATEWAY="${VPN_GATEWAY:-10.2.0.1}"
VPN_INTERFACE="${VPN_INTERFACE:-proton0}"
QBITTORRENT_URL="${QBITTORRENT_URL:-http://localhost:8081}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-45}"
STATE_DIR="${STATE_DIR:-/run/protonvpn}"
STATE_FILE="${STATE_DIR}/port-forward.state"
COOKIE_JAR="${STATE_DIR}/qbt-cookie.txt"
RECONNECT_BACKOFF_BASE="${RECONNECT_BACKOFF_BASE:-30}"
RECONNECT_BACKOFF_MAX="${RECONNECT_BACKOFF_MAX:-300}"
CURRENT_PORT=""
CURRENT_IP=""
PORT_FAIL_COUNT=0
MAX_PORT_FAILS="${MAX_PORT_FAILS:-5}"
BAD_VPN_IPS=()
VPN_DOWN_COUNT=0
RECONNECT_COUNT=0
LAST_STATUS=""

log() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') | $1"
}

log_state_change() {
	local state="$1"
	local message="$2"

	if [[ "$LAST_STATUS" != "$state" ]]; then
		LAST_STATUS="$state"
		log "$message"
	fi
}

calculate_backoff() {
	local count="$1"
	local delay="$RECONNECT_BACKOFF_BASE"
	local step=1

	while [[ $step -lt $count ]]; do
		delay=$((delay * 2))
		if [[ $delay -ge $RECONNECT_BACKOFF_MAX ]]; then
			delay="$RECONNECT_BACKOFF_MAX"
			break
		fi
		step=$((step + 1))
	done

	echo "$delay"
}

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		log "ERROR: Required command '$1' is not installed."
		exit 1
	fi
}

for cmd in curl docker fuser ip natpmpc systemctl; do
	require_command "$cmd"
done

: "${QBITTORRENT_USER:?QBITTORRENT_USER must be set in the service environment}"
: "${QBITTORRENT_PASS:?QBITTORRENT_PASS must be set in the service environment}"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

save_state() {
	umask 077
	{
		echo "CURRENT_PORT=$CURRENT_PORT"
		echo "CURRENT_IP=$CURRENT_IP"
	} >"$STATE_FILE"
}

load_state() {
	local key value

	[[ -f "$STATE_FILE" ]] || return 0

	while IFS='=' read -r key value; do
		case "$key" in
		CURRENT_PORT)
			if [[ "$value" =~ ^[0-9]+$ ]]; then
				CURRENT_PORT="$value"
			else
				log "Ignoring invalid port value in state file."
			fi
			;;
		CURRENT_IP)
			CURRENT_IP="$value"
			;;
		esac
	done <"$STATE_FILE"
}

# --- ENSURE GATEWAY ROUTE EXISTS ---
ensure_route() {
	if ! ip route show | grep -q "$VPN_GATEWAY dev $VPN_INTERFACE"; then
		log "Gateway route missing, adding..."
		ip route replace "$VPN_GATEWAY" dev "$VPN_INTERFACE" 2>/dev/null
		sleep 1
	fi
}

# --- VPN CHECK ---
vpn_up() {
	ip link show "$VPN_INTERFACE" >/dev/null 2>&1 || return 1
	ensure_route
	return 0
}

# --- FORCE WIREGUARD REKEY ---
reconnect_vpn() {
	local backoff

	RECONNECT_COUNT=$((RECONNECT_COUNT + 1))
	backoff=$(calculate_backoff "$RECONNECT_COUNT")
	log "Too many failures on $CURRENT_IP, triggering VPN reconnect..."
	log "Reconnect backoff in effect: waiting ${backoff}s before restarting protonvpn-connect.service"
	PORT_FAIL_COUNT=0
	CURRENT_PORT=""
	CURRENT_IP=""
	rm -f "$STATE_FILE"
	sleep "$backoff"
	systemctl restart protonvpn-connect.service
	exit 0
}

# --- GET PUBLIC IP ---
get_ip() {
	IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
	if [[ -z "$IP" ]]; then
		IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null)
	fi
	echo "$IP"
}

# --- GET NEW PORT ---
get_port() {
	ensure_route
	natpmpc -a 1 0 udp 60 -g "$VPN_GATEWAY" >/dev/null 2>&1
	natpmpc -a 1 0 tcp 60 -g "$VPN_GATEWAY" 2>/dev/null |
		awk '/Mapped public port/{print $4; exit}'
}

# --- REFRESH EXISTING PORT ---
refresh_port() {
	ensure_route
	natpmpc -a 1 0 udp 60 -g "$VPN_GATEWAY" >/dev/null 2>&1
	OUTPUT=$(natpmpc -a 1 "$CURRENT_PORT" tcp 60 -g "$VPN_GATEWAY" 2>/dev/null)
	echo "$OUTPUT" | grep -q "Mapped public port"
}

# --- LOGIN TO QBITTORRENT ---
qbt_login() {
	RESULT=$(curl -s -c "$COOKIE_JAR" \
		--data "username=$QBITTORRENT_USER&password=$QBITTORRENT_PASS" \
		"$QBITTORRENT_URL/api/v2/auth/login")
	log "qBittorrent login result: $RESULT"
}

# --- ENSURE QBITTORRENT CONTAINER IS RUNNING ---
ensure_qbt_running() {
	STATUS=$(docker inspect -f '{{.State.Status}}' qbittorrent 2>/dev/null)
	if [[ "$STATUS" != "running" ]]; then
		log "qBittorrent container is '$STATUS', attempting to start..."
		fuser -k "${CURRENT_PORT}/tcp" 2>/dev/null
		fuser -k "${CURRENT_PORT}/udp" 2>/dev/null
		cd /opt/qbittorrent && docker compose down 2>/dev/null
		sleep 2
		cd /opt/qbittorrent && docker compose up -d
		sleep 15
		STATUS=$(docker inspect -f '{{.State.Status}}' qbittorrent 2>/dev/null)
		if [[ "$STATUS" != "running" ]]; then
			log "ERROR: qBittorrent failed to start (status: $STATUS)"
			return 1
		fi
		log "qBittorrent container recovered (status: $STATUS)"
		qbt_login
	fi
	return 0
}

# --- SET PORT VIA API ---
qbt_set_port() {
	RESULT=$(curl -s -b "$COOKIE_JAR" \
		-X POST \
		--data "json={\"listen_port\":$CURRENT_PORT}" \
		"$QBITTORRENT_URL/api/v2/app/setPreferences")
	log "qBittorrent set port result: $RESULT"
	echo "TORRENTING_PORT=$CURRENT_PORT" >/opt/qbittorrent/.env
	cd /opt/qbittorrent && docker compose up -d --force-recreate qbittorrent
	sleep 15
	STATUS=$(docker inspect -f '{{.State.Status}}' qbittorrent 2>/dev/null)
	if [[ "$STATUS" != "running" ]]; then
		log "ERROR: qBittorrent failed to start after port change"
		return 1
	fi
	log "Docker container recreated with port $CURRENT_PORT"
	qbt_login
}

# --- LOAD STATE ---
if [[ -f "$STATE_FILE" ]]; then
	load_state
	log "Loaded state: port=$CURRENT_PORT ip=$CURRENT_IP"
	qbt_login
	qbt_set_port
	log "qBittorrent updated to port $CURRENT_PORT (from state)"
fi

log "===== ProtonVPN Port Forwarding v2 Started ====="

# Initial login
qbt_login

while true; do
	if ! vpn_up; then
		VPN_DOWN_COUNT=$((VPN_DOWN_COUNT + 1))
		log_state_change "vpn_down" "VPN interface $VPN_INTERFACE not up. Waiting for tunnel..."
		sleep 10
		continue
	fi

	VPN_DOWN_COUNT=0
	RECONNECT_COUNT=0
	log_state_change "vpn_up" "VPN interface $VPN_INTERFACE is up."

	# Ensure qBittorrent is running every loop
	ensure_qbt_running

	NEW_IP=$(get_ip)

	# Detect IP change
	if [[ -n "$NEW_IP" && "$NEW_IP" != "$CURRENT_IP" ]]; then
		log "VPN IP changed: $CURRENT_IP → $NEW_IP"
		CURRENT_IP="$NEW_IP"
		CURRENT_PORT=""
		PORT_FAIL_COUNT=0
		should_reconnect=0
		for BAD_IP in "${BAD_VPN_IPS[@]}"; do
			if [[ "$CURRENT_IP" == "$BAD_IP" ]]; then
				log "Detected bad VPN IP: $CURRENT_IP, will reconnect..."
				should_reconnect=1
				break
			fi
		done
		if [[ $should_reconnect -eq 1 ]]; then
			reconnect_vpn
		fi
	fi

	# Get or refresh port
	if [[ -z "$CURRENT_PORT" ]]; then
		log "Requesting new port..."
		CURRENT_PORT=$(get_port)
		if [[ -z "$CURRENT_PORT" ]]; then
			PORT_FAIL_COUNT=$((PORT_FAIL_COUNT + 1))
			log "ERROR: Failed to obtain port (attempt $PORT_FAIL_COUNT/$MAX_PORT_FAILS)"
			if [[ $PORT_FAIL_COUNT -ge $MAX_PORT_FAILS ]]; then
				reconnect_vpn
			fi
			sleep "$SLEEP_INTERVAL"
			continue
		fi
		PORT_FAIL_COUNT=0
		log "Obtained port: $CURRENT_PORT"
		qbt_login
		qbt_set_port || log "WARNING: Port set failed, will retry next loop"
		log "qBittorrent updated to port $CURRENT_PORT"
	else
		if refresh_port; then
			log "Port $CURRENT_PORT refreshed"
			ensure_qbt_running
		else
			log "Port refresh failed → reacquiring"
			CURRENT_PORT=""
			PORT_FAIL_COUNT=$((PORT_FAIL_COUNT + 1))
			if [[ $PORT_FAIL_COUNT -ge $MAX_PORT_FAILS ]]; then
				reconnect_vpn
			fi
			continue
		fi
	fi

	# Save state
	save_state

	sleep "$SLEEP_INTERVAL"
done
