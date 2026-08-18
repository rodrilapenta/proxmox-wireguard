#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
source "${ROOT_DIR}/VERSION"
dest_dir="${ROOT_DIR}/dashboard/dist/linux-amd64"
binary="${dest_dir}/proxmox-wireguard-dashboard"
[[ "$(uname -m)" == "x86_64" ]] || { echo "Dashboard currently supports x86_64 guests only." >&2; exit 1; }
if [[ -x "$binary" ]]; then echo "[dashboard] Linux binary already present."; exit 0; fi
command -v curl >/dev/null || { echo "curl is required to download the dashboard." >&2; exit 1; }
install -d -m 0750 "$dest_dir"
base="https://github.com/rodrilapenta/proxmox-wireguard/releases/download/v${PROJECT_VERSION}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
asset="proxmox-wireguard-dashboard-linux-amd64"
curl -fL --retry 3 -o "$tmp/$asset" "${base}/${asset}"
curl -fL --retry 3 -o "$tmp/${asset}.sha256" "${base}/${asset}.sha256"
(cd "$tmp" && sha256sum -c "${asset}.sha256")
install -m 0750 "$tmp/$asset" "$binary"
echo "[dashboard] Verified Linux binary downloaded for ${PROJECT_VERSION}."
