#!/bin/bash
# protonvpn-connect.sh
# Connects to ProtonVPN P2P with country fallbacks and starts port forwarding service.

set -u
set -o pipefail

# Countries to try in order (P2P + port forwarding capable)
COUNTRIES=("IS" "SE" "CH" "NL" "NO" "DK" "AT")

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "ERROR: Required command '$1' is not installed." >&2
		exit 1
	fi
}

for cmd in protonvpn sudo ip systemctl; do
	require_command "$cmd"
done

# Wait for network
sleep 5

# Disconnect any existing connection first
protonvpn disconnect 2>/dev/null
sleep 2

for COUNTRY in "${COUNTRIES[@]}"; do
	MAX_ATTEMPTS=3
	ATTEMPT=1
	while [[ $ATTEMPT -le $MAX_ATTEMPTS ]]; do
		echo "Connecting to $COUNTRY (attempt $ATTEMPT of $MAX_ATTEMPTS)..."

		if protonvpn connect --country "$COUNTRY" --p2p; then
			echo "Connected successfully to $COUNTRY."
			sudo ip route replace 10.2.0.1 dev proton0 2>/dev/null
			sleep 2
			sudo systemctl start protonvpn-port-forward.service
			exit 0
		fi

		echo "Failed. Retrying in 10 seconds..."
		ATTEMPT=$((ATTEMPT + 1))
		sleep 10
	done

	echo "Could not connect to $COUNTRY, trying next country..."
done

echo "ERROR: Failed to connect to any country."
exit 1
