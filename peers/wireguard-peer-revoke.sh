#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="/opt/proxmox-wireguard"
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi
[[ $EUID -eq 0 ]] || { echo "Run with sudo/root." >&2; exit 1; }

name="${1:-}"
[[ -n "$name" ]] || { echo "Usage: $0 <peer-name>" >&2; exit 2; }

peer_file="/var/lib/proxmox-wireguard/peers/${name}.conf"
[[ -f "$peer_file" ]] || { echo "Peer not found: $name" >&2; exit 1; }

rm -f "$peer_file"
rm -rf "/var/lib/proxmox-wireguard/exports/${name}"
/usr/local/sbin/wg-home-render
echo "Revoked: $name"
