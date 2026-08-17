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
[[ -f "$f" ]] || {
  echo "Export not present: $f" >&2
  echo "It may not have been generated, or it may already have been purged." >&2
  exit 1
}

cat "$f"
