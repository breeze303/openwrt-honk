#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence=${1:-"$repo_root/.cache/evidence/target-harness-contract"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$evidence/failures"
chmod 700 "$evidence"

bash -n "$repo_root/tests/quick-setup-target-harness.sh"
bash -n "$repo_root/.github/scripts/target-smoke.sh"
sh -n "$repo_root/.github/scripts/target-smoke-remote.sh"
grep -F 'TARGET_DATA_PLANE_REQUIRES_ISOLATED_FIXTURE' "$repo_root/tests/quick-setup-target-harness.sh" >/dev/null
grep -F 'networkFixture:"not-installed"' "$repo_root/.github/scripts/target-smoke-remote.sh" >/dev/null
grep -F 'privateGeoPathsAbsent' "$repo_root/.github/scripts/target-smoke-remote.sh" >/dev/null

set +e
HONK_TARGET_SSH='' "$repo_root/tests/quick-setup-target-harness.sh" --evidence "$tmp/missing"
missing_rc=$?
set -e
[ "$missing_rc" -eq 2 ]
jq -e '.ok == false and .reason == "TARGET_NOT_CONFIGURED"' "$tmp/missing/receipt.json" >/dev/null

"$repo_root/tests/quick-setup-target-harness.sh" --synthetic --preset direct --evidence "$tmp/synthetic" >/dev/null
jq -e '.ok == true and .status == "synthetic" and .presets == ["direct"]' "$tmp/synthetic/receipt.json" >/dev/null
jq -e '.ok == true and .synthetic == true and .expected.proxy == 0' "$tmp/synthetic/direct.json" >/dev/null

printf '%s\n' '{"schemaVersion":"honk.target-harness-contract.v1","ok":true,"assertions":8,"realMode":"requires-password-fd-package-and-isolated-fixture"}' >"$evidence/receipt.json"
printf 'target harness contract assertions=8\n'
