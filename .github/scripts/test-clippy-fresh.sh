#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
evidence="$repo_root/.cache/evidence/clippy-fresh"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence"
chmod 700 "$evidence"
tmp=$(mktemp -d "$repo_root/.cache/clippy-fresh.XXXXXX")

archive=$(jq -er '.source.archive.offlinePath' "$repo_root/locks/source.lock.json")
top=$(jq -er '.source.archive.topLevelDirectory' "$repo_root/locks/source.lock.json")
tar -xzf "$repo_root/$archive" -C "$tmp"
source_dir="$tmp/$top"
while IFS= read -r patch_file; do
	patch --dry-run -d "$source_dir" -p1 <"$repo_root/$patch_file" >/dev/null
	patch -d "$source_dir" -p1 <"$repo_root/$patch_file" >/dev/null
done < <(jq -er -r '.source.patchDigests[].path' "$repo_root/locks/source.lock.json")

home="$tmp/home"
cargo_home="$tmp/cargo"
target="$tmp/target"
mkdir -p "$home" "$cargo_home" "$target"
if [ -d "$HOME/.cargo/registry" ]; then ln -s "$HOME/.cargo/registry" "$cargo_home/registry"; fi
if [ -d "$HOME/.cargo/git" ]; then ln -s "$HOME/.cargo/git" "$cargo_home/git"; fi

set +e
(cd "$source_dir" && HOME="$home" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_HOME="$cargo_home" CARGO_TARGET_DIR="$target" \
	RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.97.1}" CARGO_NET_OFFLINE=true \
	cargo clippy --locked --workspace --all-targets -- -D warnings) >"$evidence/clippy.log" 2>&1
rc=$?
set -e
printf '%s\n' "$rc" >"$evidence/clippy.exit"
jq -n --arg commit "$(jq -er '.source.commit' "$repo_root/locks/source.lock.json")" \
	--arg patch "$(sha256sum "$repo_root/honk/patches/100-beta35-openwrt-contracts.patch" | cut -d ' ' -f1)" \
	--argjson rc "$rc" --arg log "$evidence/clippy.log" --arg temp "$tmp" \
	'{schemaVersion:"honk.clippy.v1",sourceCommit:$commit,geoPatchSha256:$patch,cargoNetOffline:true,command:"cargo clippy --locked --workspace --all-targets -- -D warnings",exitCode:$rc,ok:($rc==0),log:$log,freshExtraction:true,tempRoot:$temp}' \
	>"$evidence/receipt.json"
printf 'clippy exit=%s\n' "$rc"
exit "$rc"
