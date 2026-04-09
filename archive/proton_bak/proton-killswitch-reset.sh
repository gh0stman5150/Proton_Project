#!/usr/bin/env bash
iptables -F
iptables -t nat -F

iptables -P OUTPUT ACCEPT
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
