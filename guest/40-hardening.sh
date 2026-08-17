#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="/opt/proxmox-wireguard"
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

# Refuse to disable passwords unless the intended cloud-init user exists
# and has at least one authorized key.
id "$GUEST_USER" >/dev/null 2>&1 || {
  echo "User '$GUEST_USER' does not exist; refusing SSH hardening." >&2
  exit 1
}

home="$(getent passwd "$GUEST_USER" | cut -d: -f6)"
[[ -s "${home}/.ssh/authorized_keys" ]] || {
  echo "No authorized_keys for '$GUEST_USER'; refusing SSH hardening." >&2
  exit 1
}

install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/90-proxmox-wireguard.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers ${GUEST_USER}
X11Forwarding no
AllowAgentForwarding no
EOF

sshd -t
systemctl reload ssh

echo "SSH hardened: key-only, root login disabled."
