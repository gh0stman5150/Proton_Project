#!/usr/bin/env bash
# Deprecated: systemd units use proton-wg-down-safe.sh.
set -euo pipefail

wg-quick down proton || true
