#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
readonly rust_target=${RUST_TARGET:?RUST_TARGET is required}
readonly package_arch=${PACKAGE_ARCH:?PACKAGE_ARCH is required}
readonly stable_toolchain=${RUST_STABLE_TOOLCHAIN:-1.97.1}
readonly bpf_toolchain=${BPF_RUST_TOOLCHAIN:-nightly-2026-07-27}
readonly artifacts_dir=${ARTIFACTS_DIR:-$repo_root/.binary-output}
readonly work_root=${RUNNER_TEMP:-$repo_root/.cache/work}/honk-system-build-${package_arch}

retry() {
	local attempt
	for attempt in 1 2 3 4 5; do
		"$@" && return 0
		[ "$attempt" -eq 5 ] && return 1
		sleep $((attempt * 2))
	done
}

case "$rust_target:$package_arch" in
	x86_64-unknown-linux-musl:x86_64|aarch64-unknown-linux-musl:aarch64) ;;
	*) printf 'unsupported Rust target/package architecture pair: %s:%s\n' "$rust_target" "$package_arch" >&2; exit 1 ;;
esac

command -v zig >/dev/null
command -v bpf-linker >/dev/null
command -v jq >/dev/null

source_url=$(jq -er '.source.archive.url' "$repo_root/locks/source.lock.json")
source_sha=$(jq -er '.source.archive.sha256' "$repo_root/locks/source.lock.json")
source_top=$(jq -er '.source.archive.topLevelDirectory' "$repo_root/locks/source.lock.json")
source_commit=$(jq -er '.source.commit' "$repo_root/locks/source.lock.json")

rm -rf "$work_root"
mkdir -p "$work_root" "$artifacts_dir"
archive="$work_root/source.tar.gz"
retry curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
	--location --retry 5 --retry-all-errors --retry-delay 2 \
	--output "$archive" "$source_url"
printf '%s  %s\n' "$source_sha" "$archive" | sha256sum -c -
tar -xzf "$archive" -C "$work_root"
source_dir="$work_root/$source_top"
test -f "$source_dir/Cargo.toml"

while IFS=$'\t' read -r patch_path patch_sha; do
	patch_file="$repo_root/$patch_path"
	test "$(sha256sum "$patch_file" | cut -d ' ' -f 1)" = "$patch_sha"
	patch --batch --forward -d "$source_dir" -p1 <"$patch_file"
done < <(jq -r '.source.patchDigests[] | [.path, .sha256] | @tsv' "$repo_root/locks/source.lock.json")

retry rustup toolchain install "$stable_toolchain" --profile minimal --target "$rust_target"
retry rustup toolchain install "$bpf_toolchain" --profile minimal \
	--component rust-src --component llvm-tools

export CARGO_NET_RETRY=5
export CARGO_INCREMENTAL=0

(
	cd "$source_dir/crates/honk-ebpf"
	cargo "+$bpf_toolchain" build --locked --release \
		-Zbuild-std=core --target bpfel-unknown-none
)

ebpf_object="$source_dir/crates/honk-ebpf/target/bpfel-unknown-none/release/honk-ebpf"
readelf -S "$ebpf_object" | grep -q '\.BTF'

zig_target=${rust_target/-unknown/}
target_lower=$(printf '%s' "$rust_target" | tr '-' '_')
target_upper=$(printf '%s' "$rust_target" | tr 'a-z-' 'A-Z_')
export ZIGCC_TARGET="$zig_target"
export BINDGEN_EXTRA_CLANG_ARGS
BINDGEN_EXTRA_CLANG_ARGS=$("$source_dir/ci/zig-bindgen-env" "$zig_target")
export "CC_${target_lower}=$source_dir/ci/zigcc"
export "CXX_${target_lower}=$source_dir/ci/zigcxx"
export "CARGO_TARGET_${target_upper}_LINKER=$source_dir/ci/zigcc"
export "CARGO_TARGET_${target_upper}_RUSTFLAGS=-C link-self-contained=no"

(
	cd "$source_dir"
	cargo "+$stable_toolchain" build --locked --profile release-musl \
		--target "$rust_target" \
		-p honk-core -p honk-tool --features honk-core/ebpf
)

for binary_name in honk-core honk-tool; do
	binary="$source_dir/target/$rust_target/release-musl/$binary_name"
	test -x "$binary"
	if readelf -l "$binary" | grep -q 'INTERP'; then
		printf '%s contains a dynamic program interpreter\n' "$binary_name" >&2
		exit 1
	fi
	if readelf -d "$binary" 2>/dev/null | grep -q 'NEEDED'; then
		printf '%s contains a shared-library dependency\n' "$binary_name" >&2
		exit 1
	fi
	install -m 0755 "$binary" "$artifacts_dir/$binary_name"
done

jq -n \
	--arg sourceRevision "$source_commit" \
	--arg rustTarget "$rust_target" \
	--arg architecture "$package_arch" \
	--arg stableToolchain "$stable_toolchain" \
	--arg bpfToolchain "$bpf_toolchain" \
	'{sourceRevision:$sourceRevision,rustTarget:$rustTarget,architecture:$architecture,libc:"musl",linkage:"static",stableToolchain:$stableToolchain,bpfToolchain:$bpfToolchain}' \
	>"$artifacts_dir/build-manifest.json"

file "$artifacts_dir/honk-core" "$artifacts_dir/honk-tool"
sha256sum "$artifacts_dir/honk-core" "$artifacts_dir/honk-tool"
