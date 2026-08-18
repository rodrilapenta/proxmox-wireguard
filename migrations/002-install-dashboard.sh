#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="${PWG_ROOT_DIR:-/opt/proxmox-wireguard}"
"${ROOT_DIR}/guest/30-nftables.sh"
"${ROOT_DIR}/guest/55-install-dashboard.sh"
