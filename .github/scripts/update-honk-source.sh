#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
readonly upstream_url=https://github.com/Glassyiris/honk.git
readonly archive_base=https://github.com/Glassyiris/honk/archive
upstream_ref=refs/heads/main
requested_commit=''

while [ "$#" -gt 0 ]; do
	case "$1" in
		--ref) upstream_ref=$2; shift 2 ;;
		--commit) requested_commit=$2; shift 2 ;;
		*) printf 'usage: %s [--ref GIT_REF] [--commit SHA]\n' "$0" >&2; exit 64 ;;
	esac
done

retry() {
	local attempt
	for attempt in 1 2 3 4 5; do
		"$@" && return 0
		[ "$attempt" -eq 5 ] && return 1
		sleep $((attempt * 2))
	done
}

if [ -n "$requested_commit" ]; then
	source_commit=$requested_commit
else
	source_commit=$(retry git ls-remote "$upstream_url" "$upstream_ref" | awk 'NR == 1 { print $1 }')
fi
case "$source_commit" in
	????????????????????????????????????????) ;;
	*) printf 'upstream ref did not resolve to a full commit SHA: %s\n' "$upstream_ref" >&2; exit 1 ;;
esac
printf '%s' "$source_commit" | grep -Eq '^[0-9a-f]{40}$'

current_commit=$(jq -er '.source.commit' "$repo_root/locks/source.lock.json")
if [ "$source_commit" = "$current_commit" ]; then
	printf 'Honk source is current at %s\n' "$source_commit"
	if [ -n "${GITHUB_OUTPUT:-}" ]; then printf 'changed=false\n' >>"$GITHUB_OUTPUT"; fi
	exit 0
fi

work_root=$(mktemp -d)
cleanup() {
	rm -rf "$work_root"
}
trap cleanup EXIT INT TERM

archive_name="$source_commit.tar.gz"
archive_url="$archive_base/$archive_name"
archive="$work_root/$archive_name"
retry curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
	--location --retry 5 --retry-all-errors --retry-delay 2 \
	--output "$archive" "$archive_url"

archive_sha256=$(sha256sum "$archive" | cut -d ' ' -f 1)
archive_size=$(wc -c <"$archive")
top_level=$(tar -tzf "$archive" | cut -d / -f 1 | sort -u)
[ "$(printf '%s\n' "$top_level" | wc -l)" -eq 1 ]
[ "$top_level" = "honk-$source_commit" ]
tar -xzf "$archive" -C "$work_root"
source_dir="$work_root/$top_level"
[ -f "$source_dir/Cargo.toml" ]
[ -f "$source_dir/Cargo.lock" ]
[ -f "$source_dir/LICENSE" ]

# Reconstruct the Git tree recorded by the GitHub commit archive before local
# patches are applied. This gives the verifier a content and mode boundary in
# addition to the archive checksum.
GIT_MASTER=1 git -C "$source_dir" init -q
GIT_MASTER=1 git -C "$source_dir" add -A
source_tree=$(GIT_MASTER=1 git -C "$source_dir" write-tree)

patch_digests="$work_root/patch-digests.json"
: >"$patch_digests"
for patch_file in "$repo_root"/honk/patches/*.patch; do
	patch_path=${patch_file#"$repo_root/"}
	patch_sha=$(sha256sum "$patch_file" | cut -d ' ' -f 1)
	jq -nc --arg path "$patch_path" --arg sha256 "$patch_sha" \
		'{path:$path,sha256:$sha256}' >>"$patch_digests"
	patch --batch --forward -d "$source_dir" -p1 <"$patch_file"
done

tag_name=$(retry git ls-remote --tags "$upstream_url" | awk -v commit="$source_commit" '
	$1 == commit {
		name = $2
		sub(/^refs\/tags\//, "", name)
		sub(/\^\{\}$/, "", name)
		print name
	}' | sort -V | tail -n 1)

lock_tmp="$work_root/source.lock.json"
jq -S -n \
	--arg commit "$source_commit" \
	--arg tree "$source_tree" \
	--arg archiveUrl "$archive_url" \
	--arg archiveSha256 "$archive_sha256" \
	--argjson archiveSize "$archive_size" \
	--arg topLevelDirectory "$top_level" \
	--arg offlinePath ".cache/dl/honk-$source_commit.tar.gz" \
	--arg providerPath "github.com/Glassyiris/honk/archive/$archive_name" \
	--arg observedFrom "$upstream_ref" \
	--arg tagName "$tag_name" \
	--slurpfile patches "$patch_digests" \
	'{
		schemaVersion: 1,
		source: {
			archive: {
				offlinePath: $offlinePath,
				sha256: $archiveSha256,
				size: $archiveSize,
				topLevelDirectory: $topLevelDirectory,
				url: $archiveUrl
			},
			canonicalUrl: "https://github.com/Glassyiris/honk.git",
			commit: $commit,
			license: {
				sourceLicenseUrl: ("https://github.com/Glassyiris/honk/blob/" + $commit + "/LICENSE"),
				spdx: "GPL-3.0-only"
			},
			patchDigests: $patches,
			provenance: {
				archiveSource: "GitHub commit archive",
				observedFrom: $observedFrom,
				providerPath: $providerPath
			},
			tagObservation: {
				name: (if $tagName == "" then null else $tagName end),
				object: $commit,
				signatureStatus: "unverified"
			},
			tree: $tree
		}
	}' >"$lock_tmp"

mkdir -p "$repo_root/.cache/dl"
install -m 0644 "$archive" "$repo_root/.cache/dl/honk-$source_commit.tar.gz"
install -m 0644 "$lock_tmp" "$repo_root/locks/source.lock.json"
"$repo_root/.github/scripts/generate-source-lock.sh"

printf 'Updated Honk source: %s -> %s\n' "$current_commit" "$source_commit"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		printf 'changed=true\n'
		printf 'old_commit=%s\n' "$current_commit"
		printf 'new_commit=%s\n' "$source_commit"
	} >>"$GITHUB_OUTPUT"
fi
