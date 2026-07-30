#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
readonly commit=63e271065246bb68ecadf9ae53abecf748806ad3
tmp=$(mktemp -d)
assertions=0

cleanup() {
	rm -rf "$tmp" "$repo_root/.cache/dl/test-truncated.tar.gz"
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

HONK_EVIDENCE_DIR="$tmp/evidence" "$repo_root/.github/scripts/verify-source-lock.sh" --commit "$commit" --check-tree --check-archive --check-mirror-hash >/dev/null
[ -s "$tmp/evidence/source-lock/receipt.json" ]
assertions=$((assertions + 1))
must_fail old-commit "$repo_root/.github/scripts/verify-source-lock.sh" --commit 0000000000000000000000000000000000000000
must_fail floating-dev "$repo_root/.github/scripts/verify-source-lock.sh" --commit "$commit" --lock "$repo_root/tests/fixtures/source-lock-floating-dev.json"

jq '.source.tree = "0000000000000000000000000000000000000000"' "$repo_root/locks/source.lock.json" >"$tmp/wrong-tree.json"
must_fail wrong-tree "$repo_root/.github/scripts/verify-source-lock.sh" --commit "$commit" --lock "$tmp/wrong-tree.json" --check-tree

dd if="$repo_root/.cache/dl/honk-$commit.tar.gz" of="$repo_root/.cache/dl/test-truncated.tar.gz" bs=64 count=1 status=none
truncated_sha=$(sha256sum "$repo_root/.cache/dl/test-truncated.tar.gz" | cut -d ' ' -f 1)
jq --arg sha "$truncated_sha" '.source.archive.offlinePath = ".cache/dl/test-truncated.tar.gz" | .source.archive.sha256 = $sha | .source.archive.size = 64' "$repo_root/locks/source.lock.json" >"$tmp/truncated.json"
must_fail truncated-archive "$repo_root/.github/scripts/verify-source-lock.sh" --commit "$commit" --lock "$tmp/truncated.json" --check-archive

jq '.source.archive.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"' "$repo_root/locks/source.lock.json" >"$tmp/old-hash.json"
must_fail old-archive-hash "$repo_root/.github/scripts/verify-source-lock.sh" --commit "$commit" --lock "$tmp/old-hash.json"

cp -a "$repo_root/.cache/work/honk-$commit" "$tmp/feature-drift"
perl -0pi -e 's/features = \["test-util"\]/features = ["rt"]/g' "$tmp/feature-drift/crates/honk-outbound/Cargo.toml"
must_fail cargo-feature-drift "$repo_root/.github/scripts/attest-cargo-closures.sh" --source-dir "$tmp/feature-drift" --check

printf 'source-lock assertions=%s\n' "$assertions"
