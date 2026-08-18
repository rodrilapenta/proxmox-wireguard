#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT_DIR="/opt/proxmox-wireguard"
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

ts="$(date +%Y%m%d-%H%M%S)"
dest="/var/backups/proxmox-wireguard/wireguard-gateway-${ts}.tar.gz"

# Deliberately excludes /var/lib/proxmox-wireguard/exports because they can
# contain client private keys. Server key + PSKs are included, so protect backup.
backup_paths=(
  /etc/wireguard
  /etc/nftables.conf
  /etc/sysctl.d/99-proxmox-wireguard.conf
  /etc/ssh/sshd_config.d/90-proxmox-wireguard.conf
  /etc/proxmox-wireguard
  /var/lib/proxmox-wireguard/peers
  /var/lib/proxmox-wireguard/migrations
  /opt/proxmox-wireguard/config
)
existing_paths=()
for path in "${backup_paths[@]}"; do
  [[ -e "$path" ]] && existing_paths+=("$path")
done

tar -czf "$dest" "${existing_paths[@]}" 2>/dev/null

chmod 600 "$dest"
echo "$dest"
