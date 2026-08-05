#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
readonly source_commit=$(jq -er '.source.commit' "$repo_root/locks/source.lock.json")
source_dir="$repo_root/.cache/work/honk-$source_commit"
lock="$repo_root/locks/toolchains.lock.json"
check=false

while [ "$#" -gt 0 ]; do
	case "$1" in
		--source-dir) source_dir=$2; shift 2 ;;
		--lock) lock=$2; shift 2 ;;
		--check) check=true; shift ;;
		*) printf 'usage: %s [--source-dir DIR] [--lock FILE] --check\n' "$0" >&2; exit 64 ;;
	esac
done

[ -f "$source_dir/Cargo.lock" ] && [ -f "$source_dir/crates/honk-ebpf/Cargo.lock" ] || { printf 'Cargo closure source is incomplete\n' >&2; exit 1; }
[ "$(sha256sum "$source_dir/Cargo.lock" | cut -d ' ' -f 1)" = "$(jq -er '.cargoClosures.workspace.lockSha256' "$lock")" ] || { printf 'workspace Cargo.lock drift\n' >&2; exit 1; }
[ "$(sha256sum "$source_dir/crates/honk-ebpf/Cargo.lock" | cut -d ' ' -f 1)" = "$(jq -er '.cargoClosures.ebpf.lockSha256' "$lock")" ] || { printf 'eBPF Cargo.lock drift\n' >&2; exit 1; }
for closure in workspace ebpf; do
	vendor_dir="$repo_root/$(jq -er ".cargoClosures.$closure.vendorPath" "$lock")"
	[ -d "$vendor_dir" ] || { printf '%s Cargo vendor directory is missing\n' "$closure" >&2; exit 1; }
	vendor_sha=$(tar --numeric-owner --format=posix --pax-option=delete=atime,delete=ctime --sort=name --mtime='UTC 1970-01-01' -cf - -C "$vendor_dir" . | sha256sum | cut -d ' ' -f 1)
	[ "$vendor_sha" = "$(jq -er ".cargoClosures.$closure.vendorSha256" "$lock")" ] || { printf '%s Cargo vendor closure drift\n' "$closure" >&2; exit 1; }
done
grep -F 'nix = { version = "0.31", features = ["time", "fs"] }' "$source_dir/Cargo.toml" >/dev/null || { printf 'nix/fs feature edge drift\n' >&2; exit 1; }
grep -F 'thiserror.workspace = true' "$source_dir/crates/honk-outbound/Cargo.toml" >/dev/null || { printf 'honk-outbound thiserror edge drift\n' >&2; exit 1; }
grep -F 'features = ["test-util"]' "$source_dir/crates/honk-outbound/Cargo.toml" >/dev/null || { printf 'Tokio test-util feature edge drift\n' >&2; exit 1; }

rust_src_archive="$repo_root/$(jq -er '.cargoClosures.nightlyRustSrc.offlineArchivePath' "$lock")"
[ -f "$rust_src_archive" ] || { printf 'nightly rust-src archive is missing\n' >&2; exit 1; }
[ "$(sha256sum "$rust_src_archive" | cut -d ' ' -f 1)" = "$(jq -er '.cargoClosures.nightlyRustSrc.archiveSha256' "$lock")" ] || { printf 'nightly rust-src archive drift\n' >&2; exit 1; }
rust_src_lock="$repo_root/.cache/work/rust-src-nightly/rust-src-nightly/rust-src/lib/rustlib/src/rust/library/Cargo.lock"
[ -f "$rust_src_lock" ] || { printf 'nightly rust-src closure is not extracted\n' >&2; exit 1; }
[ "$(sha256sum "$rust_src_lock" | cut -d ' ' -f 1)" = "$(jq -er '.cargoClosures.nightlyRustSrc.lockSha256' "$lock")" ] || { printf 'nightly rust-src Cargo.lock drift\n' >&2; exit 1; }
[ "$(jq -er '.cargoClosures.nightlyRustSrc.status' "$lock")" = attested ] || { printf 'nightly rust-src lock state is stale\n' >&2; exit 1; }

if "$check"; then
	printf 'Cargo closures and required feature edges match their source-bound lock\n'
fi
