#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo/root." >&2; exit 1; }

name="${1:-}"
profile="${2:-split-ddns}"

case "$profile" in
  split-ddns|full-ddns|split-ip|full-ip) ;;
  *)
    echo "Profile must be one of: split-ddns | full-ddns | split-ip | full-ip" >&2
    exit 2
    ;;
esac

f="/var/lib/proxmox-wireguard/exports/${name}/${name}-${profile}.conf"
[[ -f "$f" ]] || { echo "Export not found: $f" >&2; exit 1; }

qrencode -t ANSIUTF8 <"$f"
