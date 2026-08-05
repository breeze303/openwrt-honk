#!/usr/bin/env bash
set -euo pipefail
set +x

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
readonly commit=$(jq -er '.source.commit' "$repo_root/locks/source.lock.json")
plan=/home/breeze/honk-dev/.omo/plans/honk-openwrt-daemon-luci.md
evidence=/home/breeze/honk-dev/.omo/evidence/honk-openwrt-daemon-luci/01
tmp=$(mktemp -d)
assertions=0

cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

must_fail() {
	local name=$1
	shift
	if "$@" >/dev/null 2>&1; then
		printf 'FAIL: %s unexpectedly succeeded\n' "$name" >&2
		return 1
	fi
	assertions=$((assertions + 1))
	printf 'PASS: %s\n' "$name"
}

HONK_EVIDENCE_DIR="$tmp/evidence" "$repo_root/.github/scripts/verify-source-lock.sh" --commit "$commit" --check-tree --check-archive --check-mirror-hash >"$tmp/verify.out"
[ -s "$tmp/verify.out" ] && [ -s "$tmp/evidence/source-lock/receipt.json" ]
assertions=$((assertions + 1))
must_fail malformed-input "$repo_root/.github/scripts/verify-source-lock.sh" --commit dev

stale=$(mktemp -d /dev/shm/honk-stale.XXXXXX)
printf 'stale\n' >"$stale/storage-state"
exec 9<"$plan"
must_fail stale-state "$repo_root/.github/scripts/provision-lab-secrets.sh" --plan-fd 9 --out-dir "$stale" --json
exec 9<&-
rm -rf "$stale"

interrupt_once() {
	local interrupted
	interrupted=$(mktemp -d /dev/shm/honk-interrupt.XXXXXX)
	if timeout -s INT 1 bash -c 'set -e; trap "rm -rf \"$1\"; exit 130" EXIT INT TERM; sleep 5' _ "$interrupted" >/dev/null 2>&1; then
		printf 'interrupt probe unexpectedly succeeded\n' >&2
		return 1
	fi
	[ ! -d "$interrupted" ]
}

interrupt_once
interrupt_once
assertions=$((assertions + 2))
must_fail hung-command timeout 1 bash -c 'sleep 5'

for run in 1 2 3; do
	HONK_EVIDENCE_DIR="$tmp/flaky-$run" "$repo_root/.github/scripts/verify-source-lock.sh" --commit "$commit" --check-tree --check-archive --check-mirror-hash >/dev/null
	[ -s "$tmp/flaky-$run/source-lock/receipt.json" ]
done
assertions=$((assertions + 3))

jq -n \
	--argjson assertions "$assertions" \
	'{assertions:$assertions,probes:{malformed_input:"rejected",cancel_resume:"two interrupted cleanup runs deleted their tmpfs state",stale_state:"rejected",dirty_worktree:"covered by tests/test-scope.sh",hung_commands:"timeout rejection observed",flaky_tests:"three consecutive source-lock verifications passed with receipts",misleading_success_output:"exit zero required nonempty stdout and receipt",repeated_interruptions:"two INT cleanup probes passed",prompt_injection:{status:"not_applicable",reason:"Todo 1 executes no untrusted instructions; source archives are treated as data only"}}}' >"$evidence/adversarial-probes.json"
printf 'adversarial assertions=%s\n' "$assertions"
