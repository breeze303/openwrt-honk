#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/geo-rust"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence"
chmod 700 "$evidence"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

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
rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
mkdir -p "$home" "$cargo_home" "$target"
if [ -d "$HOME/.cargo/registry" ]; then ln -s "$HOME/.cargo/registry" "$cargo_home/registry"; fi
if [ -d "$HOME/.cargo/git" ]; then ln -s "$HOME/.cargo/git" "$cargo_home/git"; fi

(cd "$source_dir" && HOME="$home" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" CARGO_TARGET_DIR="$target" \
	RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.97.1}" CARGO_NET_OFFLINE=true \
	cargo check -p honk-tool --message-format=short) >"$evidence/cargo-check.log" 2>&1
(cd "$source_dir" && HOME="$home" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" CARGO_TARGET_DIR="$target" \
	RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.97.1}" CARGO_NET_OFFLINE=true \
	cargo test -p honk-tool geo::tests -- --nocapture) >"$evidence/geo-tests.log" 2>&1

jq -n --arg commit "$(jq -er '.source.commit' "$repo_root/locks/source.lock.json")" \
	--arg patch "$(sha256sum "$repo_root/honk/patches/100-beta35-openwrt-contracts.patch" | cut -d ' ' -f1)" \
	'{schemaVersion:"honk.geo-rust.v1",sourceCommit:$commit,geoPatchSha256:$patch,cargoNetOffline:true,tests:["cargo check -p honk-tool","cargo test -p honk-tool geo::tests"],assertions:2,ok:true}' \
	>"$evidence/receipt.json"
printf 'geo-rust assertions=2\n'
