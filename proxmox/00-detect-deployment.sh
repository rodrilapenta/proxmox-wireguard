#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then source "${ROOT_DIR}/config/resolved.conf"; else source "${ROOT_DIR}/config/env.conf"; fi
VM_NAME="${MANAGED_VM_NAME:-${VM_NAME:-wireguard-gateway}}"
MANAGED_TAG="${MANAGED_TAG:-proxmox-wireguard-managed}"

managed_ids=()
legacy_ids=()
while read -r id; do
  [[ "$id" =~ ^[0-9]+$ ]] || continue
  cfg="$(qm config "$id" 2>/dev/null || true)"
  tags="$(awk -F': ' '/^tags:/ {print $2; exit}' <<<"$cfg")"
  name="$(awk -F': ' '/^name:/ {print $2; exit}' <<<"$cfg")"
  if tr ';' '\n' <<<"$tags" | grep -Fxq "$MANAGED_TAG"; then managed_ids+=("$id")
  elif [[ "$name" == "$VM_NAME" ]]; then legacy_ids+=("$id")
  fi
done < <(qm list | awk 'NR>1{print $1}')

printf 'MANAGED_IDS=%s\n' "${managed_ids[*]:-}"
printf 'LEGACY_IDS=%s\n' "${legacy_ids[*]:-}"

KEY_EXISTS=0
KEY_PAIR_VALID=0
KEY_FINGERPRINT=""
if [[ -f "$SSH_PRIVATE_KEY" || -f "${SSH_PRIVATE_KEY}.pub" ]]; then
  KEY_EXISTS=1
fi
if [[ -f "$SSH_PRIVATE_KEY" && -f "${SSH_PRIVATE_KEY}.pub" ]]; then
  # ssh-keygen -y prints "<type> <base64>". Normalize the .pub file to those
  # same two fields, ignoring its optional comment.
  derived="$(ssh-keygen -y -f "$SSH_PRIVATE_KEY" 2>/dev/null | awk '{print $1" "$2}' || true)"
  stored="$(awk 'NF>=2 {print $1" "$2; exit}' "${SSH_PRIVATE_KEY}.pub" 2>/dev/null || true)"
  if [[ -n "$derived" && -n "$stored" && "$stored" == "$derived" ]]; then
    KEY_PAIR_VALID=1
    KEY_FINGERPRINT="$(ssh-keygen -lf "${SSH_PRIVATE_KEY}.pub" -E sha256 | awk '{print $2}')"
  fi
fi
printf 'KEY_EXISTS=%s\n' "$KEY_EXISTS"
printf 'KEY_PAIR_VALID=%s\n' "$KEY_PAIR_VALID"
printf 'KEY_FINGERPRINT=%s\n' "$KEY_FINGERPRINT"
