#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

name="${1:-wireguard-ready-01}"

# Proxmox configuration IDs must start with a letter and then contain
# letters, digits, underscore or dash.
if [[ ! "$name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
  echo "Invalid Proxmox snapshot name: $name" >&2
  exit 2
fi

if qm listsnapshot "$VMID" 2>/dev/null | grep -Fq "$name"; then
  echo "[INFO] Snapshot already exists: $name"
  exit 0
fi

qm snapshot "$VMID" "$name" --description "proxmox-wireguard known-good state"
echo "[OK] Created snapshot: $name"
