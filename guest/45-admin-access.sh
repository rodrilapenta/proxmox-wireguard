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

ADMIN_KEYS_FILE="/etc/proxmox-wireguard-admin.keys"
ADMIN_MARKER_BEGIN="# BEGIN proxmox-wireguard human admin keys"
ADMIN_MARKER_END="# END proxmox-wireguard human admin keys"

ensure_user() {
  id "$GUEST_USER" >/dev/null 2>&1 || {
    echo "User '$GUEST_USER' does not exist." >&2
    exit 1
  }
}

install_admin_key() {
  local key="$1"
  local home auth tmp
  ensure_user
  home="$(getent passwd "$GUEST_USER" | cut -d: -f6)"
  install -d -m 0700 -o "$GUEST_USER" -g "$GUEST_USER" "${home}/.ssh"
  auth="${home}/.ssh/authorized_keys"
  touch "$auth"
  chown "$GUEST_USER:$GUEST_USER" "$auth"
  chmod 0600 "$auth"

  if ! grep -Fxq "$key" "$auth"; then
    printf '%s\n' "$key" >>"$auth"
  fi
}

set_console_password() {
  ensure_user
  echo
  echo "Set a local emergency console password for '$GUEST_USER'."
  echo "This password will NOT enable SSH password authentication."
  passwd "$GUEST_USER"
}

echo
echo "Human administrator access"
echo "--------------------------"
echo "The deployment key is reserved for automation/recovery."
echo "You may add a separate SSH public key for normal administration."
echo

if [[ -t 0 ]]; then
  echo "Administrator SSH access:"
  echo "  1) Paste an existing SSH public key"
  echo "  2) Skip for now"
  read -r -p "Choice [2]: " choice
  choice="${choice:-2}"

  case "$choice" in
    1)
      read -r -p "Paste SSH public key: " admin_key
      if [[ "$admin_key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]]+ ]]; then
        install_admin_key "$admin_key"
        echo "[OK] Administrator public key installed for '$GUEST_USER'."
      else
        echo "Invalid/unsupported SSH public key format." >&2
        exit 1
      fi
      ;;
    2) echo "[INFO] Human administrator SSH key skipped." ;;
    *) echo "Invalid choice." >&2; exit 2 ;;
  esac

  echo
  read -r -p "Set an emergency local console password for '$GUEST_USER'? [y/N]: " pw_answer
  case "${pw_answer,,}" in
    y|yes) set_console_password ;;
    *) echo "[INFO] Console password skipped." ;;
  esac
else
  echo "[INFO] Non-interactive execution: administrator-key/password prompts skipped."
fi
