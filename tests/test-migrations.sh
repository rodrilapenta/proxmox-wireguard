#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/package"
cp -a "$ROOT_DIR/migrations" "$test_root/package/migrations"
mkdir -p "$test_root/package/guest"
printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n' >"$test_root/package/guest/30-nftables.sh"
printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n' >"$test_root/package/guest/55-install-dashboard.sh"
chmod 0700 "$test_root/package/guest/30-nftables.sh" "$test_root/package/guest/55-install-dashboard.sh"

export PWG_ROOT_DIR="$test_root/package"
export PWG_STATE_DIR="$test_root/state"
export PWG_CONFIG_DIR="$test_root/config"
export PWG_TEST_MODE=1

bash "$ROOT_DIR/guest/apply-migrations.sh"
marker="$PWG_STATE_DIR/migrations/001-initialize-versioned-state.applied"
[[ -s "$marker" ]] || { echo "Migration marker was not created." >&2; exit 1; }

before="$(cat "$marker")"
bash "$ROOT_DIR/guest/apply-migrations.sh"
after="$(cat "$marker")"
[[ "$before" == "$after" ]] || { echo "Applied migration ran more than once." >&2; exit 1; }

echo "Migration runner tests passed."
