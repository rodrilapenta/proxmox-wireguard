#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
if [[ -f "${ROOT_DIR}/config/resolved.conf" ]]; then
  source "${ROOT_DIR}/config/resolved.conf"
else
  source "${ROOT_DIR}/config/env.conf"
fi

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[prepare] $*"; }

[[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host."
command -v qm >/dev/null || die "qm not found. Run this on Proxmox VE."

mkdir -p "$(dirname "$SSH_PRIVATE_KEY")"
if [[ ! -f "$SSH_PRIVATE_KEY" ]]; then
  log "Generating dedicated deployment SSH key: $SSH_PRIVATE_KEY"
  ssh-keygen -q -t ed25519 -N "" -C "proxmox-wireguard-managed-deploy" -f "$SSH_PRIVATE_KEY"
else
  log "SSH key already exists; keeping it."
fi

mkdir -p "$(dirname "$DEBIAN_IMAGE_CACHE")"

tmp_img="${DEBIAN_IMAGE_CACHE}.download"
tmp_sum="${DEBIAN_IMAGE_CACHE}.SHA512SUMS"

if [[ ! -s "$DEBIAN_IMAGE_CACHE" ]]; then
  log "Downloading official Debian 13 genericcloud image..."
  curl -fL --retry 3 --connect-timeout 15 "$DEBIAN_IMAGE_URL" -o "$tmp_img"
  curl -fL --retry 3 --connect-timeout 15 "$DEBIAN_SHA512_URL" -o "$tmp_sum"

  image_name="$(basename "$DEBIAN_IMAGE_URL")"
  expected="$(awk -v f="$image_name" '$2==f || $2=="*"f {print $1; exit}' "$tmp_sum")"
  [[ -n "$expected" ]] || die "Could not find $image_name in SHA512SUMS."

  actual="$(sha512sum "$tmp_img" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || die "SHA512 verification FAILED."

  mv -f "$tmp_img" "$DEBIAN_IMAGE_CACHE"
  rm -f "$tmp_sum"
  log "Image downloaded and SHA512 verified."
else
  log "Cached Debian image exists: $DEBIAN_IMAGE_CACHE"
fi

log "Preparation complete."
echo "SSH public key:"
cat "${SSH_PRIVATE_KEY}.pub"
