#!/usr/bin/env bash
# Deprecated: systemd units use proton-killswitch-safe.sh.
set -euo pipefail

VPN_IF="wg0"
LAN_IF="$(ip route | grep default | awk '{print $5}' | head -n1)"

# Flush existing rules
iptables -F
iptables -t nat -F

# Default deny
iptables -P OUTPUT DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# Allow LAN (so you don’t lock yourself out)
iptables -A OUTPUT -o "$LAN_IF" -j ACCEPT
iptables -A INPUT -i "$LAN_IF" -j ACCEPT

# Allow VPN tunnel traffic
iptables -A OUTPUT -o "$VPN_IF" -j ACCEPT
iptables -A INPUT -i "$VPN_IF" -j ACCEPT

# Allow established connections
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
