#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
ROOT_DIR="/opt/proxmox-wireguard"
source "${ROOT_DIR}/config/resolved.conf"
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

binary="${ROOT_DIR}/dashboard/dist/linux-amd64/proxmox-wireguard-dashboard"
[[ -x "$binary" ]] || { echo "Dashboard Linux binary missing: $binary" >&2; exit 1; }
[[ -s /etc/proxmox-wireguard/dashboard-password ]] || { echo "Dashboard password hash is not configured." >&2; exit 1; }

missing_packages=()
for package in openssl sudo speedtest-cli; do dpkg -s "$package" >/dev/null 2>&1 || missing_packages+=("$package"); done
if (( ${#missing_packages[@]} > 0 )); then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
fi

id proxmox-wireguard-dashboard >/dev/null 2>&1 || useradd --system --home /var/lib/proxmox-wireguard-dashboard --create-home --shell /usr/sbin/nologin proxmox-wireguard-dashboard
chown root:proxmox-wireguard-dashboard /etc/proxmox-wireguard
chmod 0750 /etc/proxmox-wireguard
install -m 0755 "$binary" /usr/local/bin/proxmox-wireguard-dashboard
install -d -m 0755 /usr/local/libexec
install -m 0750 "${ROOT_DIR}/guest/dashboard-helper.sh" /usr/local/libexec/proxmox-wireguard-dashboard-helper

install -d -m 0750 -o root -g proxmox-wireguard-dashboard /etc/proxmox-wireguard/tls
if [[ ! -s /etc/proxmox-wireguard/tls/dashboard.key || ! -s /etc/proxmox-wireguard/tls/dashboard.crt ]]; then
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -subj "/CN=${VM_IP}" -addext "subjectAltName=IP:${VM_IP},IP:${WG_SERVER_IP}" \
    -keyout /etc/proxmox-wireguard/tls/dashboard.key -out /etc/proxmox-wireguard/tls/dashboard.crt
fi
chown root:proxmox-wireguard-dashboard /etc/proxmox-wireguard/dashboard-password /etc/proxmox-wireguard/tls/dashboard.key /etc/proxmox-wireguard/tls/dashboard.crt
chmod 0640 /etc/proxmox-wireguard/dashboard-password /etc/proxmox-wireguard/tls/dashboard.key
chmod 0644 /etc/proxmox-wireguard/tls/dashboard.crt

rm -f /etc/sudoers.d/proxmox-wireguard-dashboard

cat >/etc/systemd/system/proxmox-wireguard-dashboard-helper.service <<'EOF'
[Unit]
Description=Proxmox WireGuard Dashboard privileged helper
Before=proxmox-wireguard-dashboard.service

[Service]
Type=simple
User=root
Group=proxmox-wireguard-dashboard
RuntimeDirectory=proxmox-wireguard-dashboard
RuntimeDirectoryMode=0750
ExecStart=/usr/local/bin/proxmox-wireguard-dashboard --helper-server
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/proxmox-wireguard /etc/wireguard
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/proxmox-wireguard-dashboard.service <<EOF
[Unit]
Description=Proxmox WireGuard Dashboard
After=network-online.target wg-quick@${WG_IF}.service proxmox-wireguard-dashboard-helper.service
Wants=network-online.target
Requires=proxmox-wireguard-dashboard-helper.service

[Service]
Type=simple
User=proxmox-wireguard-dashboard
Group=proxmox-wireguard-dashboard
ExecStart=/usr/local/bin/proxmox-wireguard-dashboard --mode system --listen 0.0.0.0:${DASHBOARD_PORT:-8443} --tls-cert /etc/proxmox-wireguard/tls/dashboard.crt --tls-key /etc/proxmox-wireguard/tls/dashboard.key
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
StateDirectory=proxmox-wireguard-dashboard
StateDirectoryMode=0700
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now proxmox-wireguard-dashboard-helper proxmox-wireguard-dashboard
echo "Dashboard installed at https://${VM_IP}:${DASHBOARD_PORT:-8443}/"
