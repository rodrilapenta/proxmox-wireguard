#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

STAGED_ROOT="${1:-}"
INSTALL_ROOT="/opt/proxmox-wireguard"
STATE_DIR="/var/lib/proxmox-wireguard"

die(){ echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Run as root."
[[ -n "$STAGED_ROOT" && -d "$STAGED_ROOT" ]] || die "Staged package directory is required."
[[ -f "${STAGED_ROOT}/VERSION" ]] || die "Staged package has no VERSION manifest."

# shellcheck source=/dev/null
source "${STAGED_ROOT}/VERSION"
[[ "${PROJECT_VERSION:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid PROJECT_VERSION."
[[ "${STATE_SCHEMA_VERSION:-}" =~ ^[0-9]+$ ]] || die "Invalid STATE_SCHEMA_VERSION."

install -d -m 0700 "$STATE_DIR"
install -d -m 0750 /etc/proxmox-wireguard
if getent group proxmox-wireguard-dashboard >/dev/null 2>&1; then
  chown root:proxmox-wireguard-dashboard /etc/proxmox-wireguard
fi
new_root="/opt/proxmox-wireguard.new.$$"
old_root="/opt/proxmox-wireguard.previous.$$"
cleanup(){ rm -rf "$new_root"; }
trap cleanup EXIT

cp -a "$STAGED_ROOT" "$new_root"
if [[ -f "${INSTALL_ROOT}/config/resolved.conf" ]]; then
  install -m 0600 "${INSTALL_ROOT}/config/resolved.conf" "${new_root}/config/resolved.conf"
fi
if [[ -d "$INSTALL_ROOT" ]]; then mv "$INSTALL_ROOT" "$old_root"; fi
mv "$new_root" "$INSTALL_ROOT"

rollback(){
  rc=$?
  if (( rc != 0 )) && [[ -d "$old_root" ]]; then
    rm -rf "$INSTALL_ROOT"
    mv "$old_root" "$INSTALL_ROOT"
    echo "Update failed; previous application files were restored." >&2
  fi
  exit "$rc"
}
trap rollback ERR

"${INSTALL_ROOT}/guest/apply-migrations.sh"
"${INSTALL_ROOT}/guest/15-persist-metadata.sh"
"${INSTALL_ROOT}/guest/60-healthcheck.sh"
"${INSTALL_ROOT}/guest/record-version.sh"
rm -rf "$old_root"
trap - ERR
echo "[OK] Updated to ${PROJECT_VERSION} (schema ${STATE_SCHEMA_VERSION})."
