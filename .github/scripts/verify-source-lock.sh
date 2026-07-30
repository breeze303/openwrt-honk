#!/usr/bin/env bash
set -euo pipefail
set +x

readonly expected_commit=63e271065246bb68ecadf9ae53abecf748806ad3
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
lock="$repo_root/locks/source.lock.json"
requested_commit=''
check_tree=false
check_archive=false
check_mirror_hash=false
receipt_dir="${HONK_EVIDENCE_DIR:-/home/breeze/honk-dev/.omo/evidence/honk-openwrt-daemon-luci/01}/source-lock"

while [ "$#" -gt 0 ]; do
	case "$1" in
		--lock) lock=$2; shift 2 ;;
		--commit) requested_commit=$2; shift 2 ;;
		--check-tree) check_tree=true; shift ;;
		--check-archive) check_archive=true; shift ;;
		--check-mirror-hash) check_mirror_hash=true; shift ;;
		--receipt-dir) receipt_dir=$2; shift 2 ;;
		*) printf 'usage: %s --commit SHA [--lock FILE] [--check-tree] [--check-archive] [--check-mirror-hash]\n' "$0" >&2; exit 64 ;;
	esac
done

fail() {
	printf 'source-lock verification failed: %s\n' "$1" >&2
	exit 1
}

[ "$requested_commit" = "$expected_commit" ] || fail 'requested commit is not the frozen commit'
jq -e --arg commit "$expected_commit" '
	.schemaVersion == 1 and
	.source.canonicalUrl == "https://github.com/Glassyiris/honk.git" and
	.source.commit == $commit and
	.source.commit != "dev" and
	(.source.tree | test("^[0-9a-f]{40}$")) and
	.source.tagObservation.name == "v0.0.1.beta.25" and
	.source.tagObservation.signatureStatus == "unsigned" and
	(.source.archive.url | test("^https://github\\.com/Glassyiris/honk/archive/[0-9a-f]{40}\\.tar\\.gz$")) and
	(.source.archive.sha256 | test("^[0-9a-f]{64}$")) and
	(.source.archive.size | type == "number" and . > 0) and
	(.source.archive.topLevelDirectory | type == "string" and length > 0) and
	(.source.archive.offlinePath | test("^(?!/)(?!.*\\.\\.)[A-Za-z0-9._/-]+$")) and
	(.source.patchDigests | type == "array")
' "$lock" >/dev/null || fail 'schema or immutable-source fields are invalid'

archive_rel=$(jq -er '.source.archive.offlinePath' "$lock")
archive="$repo_root/$archive_rel"
[ -f "$archive" ] || fail 'locked archive is missing'
expected_sha=$(jq -er '.source.archive.sha256' "$lock")
expected_size=$(jq -er '.source.archive.size' "$lock")
actual_sha=$(sha256sum "$archive" | cut -d ' ' -f 1)
actual_size=$(wc -c <"$archive")
[ "$actual_sha" = "$expected_sha" ] || fail 'archive SHA-256 mismatch'
[ "$actual_size" = "$expected_size" ] || fail 'archive size mismatch'

if "$check_archive" || "$check_tree"; then
	top_level=$(tar -tzf "$archive" | cut -d / -f 1 | sort -u)
	[ "$(printf '%s\n' "$top_level" | wc -l)" -eq 1 ] || fail 'archive has multiple top-level directories'
	[ "$top_level" = "$(jq -er '.source.archive.topLevelDirectory' "$lock")" ] || fail 'archive top-level directory mismatch'
fi

if "$check_tree"; then
	tmp=$(mktemp -d)
	cleanup() {
		rm -rf "$tmp"
	}
	trap cleanup EXIT INT TERM
	tar -xzf "$archive" -C "$tmp"
	GIT_MASTER=1 git -C "$tmp/$top_level" init -q
	GIT_MASTER=1 git -C "$tmp/$top_level" add -A
	actual_tree=$(GIT_MASTER=1 git -C "$tmp/$top_level" write-tree)
	expected_tree=$(jq -er '.source.tree' "$lock")
	[ "$actual_tree" = "$expected_tree" ] || fail 'reconstructed archive tree mismatch'
	fi

if "$check_mirror_hash"; then
	grep -Fx "PKG_SOURCE_VERSION:=$expected_commit" "$repo_root/honk/source.mk" >/dev/null || fail 'source Makefile fragment has wrong revision'
	grep -Fx "PKG_MIRROR_HASH:=$expected_sha" "$repo_root/honk/source.mk" >/dev/null || fail 'source Makefile fragment has wrong mirror hash'
	grep -Fx 'include $(CURDIR)/source.mk' "$repo_root/honk/Makefile" >/dev/null || fail 'package Makefile does not include lock-derived source fragment'
	fi

mkdir -p "$receipt_dir"
jq -n \
	--arg commit "$expected_commit" \
	--arg tree "$(jq -er '.source.tree' "$lock")" \
	--arg archiveSha256 "$actual_sha" \
	--argjson archiveSize "$actual_size" \
	--arg checkedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	'{commit:$commit,tree:$tree,archiveSha256:$archiveSha256,archiveSize:$archiveSize,checkedAt:$checkedAt}' >"$receipt_dir/receipt.json"
printf 'source lock verified\n'
