#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${PWG_STATE_DIR:-/var/lib/proxmox-wireguard}"
CONFIG_DIR="${PWG_CONFIG_DIR:-/etc/proxmox-wireguard}"
install -d -m 0700 "${STATE_DIR}/migrations"
install -d -m 0700 "$CONFIG_DIR"

# Version 1.0.0 deployments predate migration markers. Existing WireGuard,
# peer, and deployment files are intentionally left untouched.
echo "Initialized versioned deployment state."
