#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/config/resolved.conf"
force=0
if [[ "${1:-}" == "--force" ]]; then force=1; shift; fi
guest_package="${1:-/opt/proxmox-wireguard}"
ssh_opts=(-i "$SSH_PRIVATE_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
target="${GUEST_USER}@${VM_IP}"

if (( force == 0 )) && ssh "${ssh_opts[@]}" "$target" 'sudo test -s /etc/proxmox-wireguard/dashboard-password'; then
  echo "[dashboard] Existing administrator password preserved."
  exit 0
fi

binary="${guest_package}/dashboard/dist/linux-amd64/proxmox-wireguard-dashboard"
ssh "${ssh_opts[@]}" "$target" "sudo test -x '$binary'" || { echo "Dashboard Linux binary missing in package." >&2; exit 1; }

while true; do
  read -r -s -p "Dashboard administrator password (minimum 8 characters): " password; echo
  read -r -s -p "Confirm dashboard password: " confirmation; echo
  [[ ${#password} -ge 8 ]] || { echo "Password is too short." >&2; continue; }
  [[ "$password" == "$confirmation" ]] || { echo "Passwords do not match." >&2; continue; }
  break
done
hash="$(printf '%s' "$password" | ssh "${ssh_opts[@]}" "$target" "sudo '$binary' --hash-password")"
unset password confirmation
[[ "$hash" == '$2'* ]] || { echo "Guest returned an invalid password hash." >&2; exit 1; }
printf '%s\n' "$hash" | ssh "${ssh_opts[@]}" "$target" '
  sudo install -d -m 0750 /etc/proxmox-wireguard
  sudo sh -c "umask 077; cat > /etc/proxmox-wireguard/dashboard-password"
  if getent group proxmox-wireguard-dashboard >/dev/null 2>&1; then
    sudo chown root:proxmox-wireguard-dashboard /etc/proxmox-wireguard /etc/proxmox-wireguard/dashboard-password
    sudo chmod 0750 /etc/proxmox-wireguard
    sudo chmod 0640 /etc/proxmox-wireguard/dashboard-password
  fi
'
echo "[dashboard] Administrator password configured."
