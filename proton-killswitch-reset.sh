#!/usr/bin/env bash
nft delete table inet proton 2>/dev/null || true
iptables -D INPUT -j PROTON_INPUT 2>/dev/null || true
iptables -D OUTPUT -j PROTON_OUTPUT 2>/dev/null || true
iptables -F PROTON_INPUT 2>/dev/null || true
iptables -F PROTON_OUTPUT 2>/dev/null || true
iptables -X PROTON_INPUT 2>/dev/null || true
iptables -X PROTON_OUTPUT 2>/dev/null || true

iptables -P OUTPUT ACCEPT
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT

nft delete table ip proton_nat 2>/dev/null || true
iptables -t nat -D POSTROUTING -j PROTON_POSTROUTING 2>/dev/null || true
iptables -t nat -F PROTON_POSTROUTING 2>/dev/null || true
iptables -t nat -X PROTON_POSTROUTING 2>/dev/null || true
