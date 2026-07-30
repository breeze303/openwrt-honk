#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
lock="$repo_root/locks/source.lock.json"
out="$repo_root/honk/source.mk"
check=false

while [ "$#" -gt 0 ]; do
	case "$1" in
		--lock) lock=$2; shift 2 ;;
		--out) out=$2; shift 2 ;;
		--check) check=true; shift ;;
		*) printf 'usage: %s [--lock FILE] [--out FILE] [--check]\n' "$0" >&2; exit 64 ;;
	esac
done

source_commit=$(jq -er '.source.commit | select(test("^[0-9a-f]{40}$"))' "$lock")
archive_sha256=$(jq -er '.source.archive.sha256 | select(test("^[0-9a-f]{64}$"))' "$lock")
archive_url=$(jq -er '.source.archive.url | select(startswith("https://"))' "$lock")
source_name=$(basename "$archive_url")

generated=$(mktemp)
cleanup() {
	rm -f "$generated"
}
trap cleanup EXIT INT TERM

cat >"$generated" <<EOF
# Generated from locks/source.lock.json. Do not edit.
PKG_SOURCE_VERSION:=$source_commit
PKG_SOURCE:=$source_name
PKG_SOURCE_URL:=$(dirname "$archive_url")
PKG_MIRROR_HASH:=$archive_sha256
EOF

if "$check"; then
	cmp -s "$generated" "$out"
	printf 'source lock Makefile fragment is current\n'
	exit 0
fi

mkdir -p "$(dirname -- "$out")"
mv "$generated" "$out"
trap - EXIT INT TERM
