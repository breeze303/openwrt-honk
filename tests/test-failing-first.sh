#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture="$repo_root/tests/fixtures/source-lock-floating-dev.json"
plan="$repo_root/tests/fixtures/plan-malformed-marker.txt"
out_dir=$(mktemp -d /dev/shm/honk-failing-first.XXXXXX)

cleanup() {
	rm -rf "$out_dir"
}
trap cleanup EXIT INT TERM

must_fail() {
	local name=$1
	shift
	if "$@"; then
		printf 'FAIL: %s unexpectedly succeeded\n' "$name" >&2
		return 1
	fi
	printf 'PASS: %s rejected\n' "$name"
}

must_fail floating-source "$repo_root/.github/scripts/verify-source-lock.sh" --commit 63e271065246bb68ecadf9ae53abecf748806ad3 --lock "$fixture"
exec 9<"$plan"
must_fail malformed-marker "$repo_root/.github/scripts/provision-lab-secrets.sh" --plan-fd 9 --out-dir "$out_dir" --json
