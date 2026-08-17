#!/usr/bin/env bash
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo/root." >&2; exit 1; }
name="${1:-}"
[[ -n "$name" ]] || { echo "Usage: $0 <peer-name>" >&2; exit 2; }

dir="/var/lib/proxmox-wireguard/exports/${name}"
[[ -d "$dir" ]] || { echo "No exports exist for: $name"; exit 0; }

# shred is best-effort only (especially on SSD/thin storage), so the real
# protection is keeping this directory root-only and purging promptly.
find "$dir" -type f -exec shred -u {} \; 2>/dev/null || rm -f "$dir"/*
rmdir "$dir" 2>/dev/null || true
echo "Client export material purged for: $name"
echo "Server peer remains active."
