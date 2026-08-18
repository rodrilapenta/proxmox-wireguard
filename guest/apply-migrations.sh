#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="${PWG_ROOT_DIR:-/opt/proxmox-wireguard}"
STATE_DIR="${PWG_STATE_DIR:-/var/lib/proxmox-wireguard}"
MIGRATION_DIR="${STATE_DIR}/migrations"
if [[ $EUID -ne 0 && "${PWG_TEST_MODE:-0}" != "1" ]]; then
  echo "Run as root." >&2
  exit 1
fi
install -d -m 0700 "$MIGRATION_DIR"

for migration in "${ROOT_DIR}"/migrations/[0-9][0-9][0-9]-*.sh; do
  [[ -e "$migration" ]] || continue
  migration_name="$(basename "$migration" .sh)"
  marker="${MIGRATION_DIR}/${migration_name}.applied"
  if [[ -f "$marker" ]]; then
    echo "[SKIP] ${migration_name}"
    continue
  fi
  echo "[RUN] ${migration_name}"
  bash "$migration"
  printf 'applied_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$marker"
  chmod 0600 "$marker"
done
