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

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

apt-get update
apt-get install -y \
  locales wireguard-tools nftables qrencode \
  qemu-guest-agent unattended-upgrades apt-listchanges \
  curl ca-certificates jq iproute2 iputils-ping dnsutils \
  rsync openssh-server

cat >/etc/default/locale <<'EOF'
LANG=C.UTF-8
LC_ALL=C.UTF-8
EOF

# qemu-guest-agent may be a static unit on current Debian. Start it if possible;
# Proxmox/udev can activate it without an [Install] section.
systemctl start qemu-guest-agent || true

cat >/etc/sysctl.d/99-proxmox-wireguard.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
# Loose reverse-path filtering is friendlier to routed/VPN traffic.
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
sysctl --system >/dev/null

cat >/etc/apt/apt.conf.d/52proxmox-wireguard-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

dpkg-reconfigure -f noninteractive unattended-upgrades || true

install -d -m 0700 /var/lib/proxmox-wireguard
install -d -m 0700 /var/lib/proxmox-wireguard/peers
install -d -m 0700 /var/lib/proxmox-wireguard/exports
install -d -m 0700 /var/backups/proxmox-wireguard

echo "Base system configured."
