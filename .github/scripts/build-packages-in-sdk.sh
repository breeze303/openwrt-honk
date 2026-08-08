#!/usr/bin/env bash
set -euo pipefail

readonly feed_dir=${FEED_DIR:-/feed}
readonly artifacts_dir=${ARTIFACTS_DIR:-/artifacts}
readonly feed_name=${FEED_NAME:-honk_ci}
readonly bpf_toolchain=${BPF_RUST_TOOLCHAIN:-nightly-2026-07-20}
readonly bpf_linker_version=${BPF_LINKER_VERSION:-0.10.4}
readonly bpf_linker_sha256=${BPF_LINKER_SHA256:-4dda77daab6c5f120a468e6d3ede2498f5bd47ece712172cfb7290176d93d015}
readonly rust_feed_commit=${RUST_FEED_COMMIT:-2006dff59caa09bc3bc22ffdc84df2aa1c8d0c8a}
readonly sccache_version=${SCCACHE_VERSION:-0.17.0}
readonly sccache_sha256=${SCCACHE_SHA256:-67c4a96dd237c1f518f6b36083f270f9976d516f1e57fce891755ea782e50006}
readonly sdk_cache_dir=${SDK_CACHE_DIR:-}
readonly sccache_cache_size=${SCCACHE_CACHE_SIZE:-768M}

cache_enabled=false
rust_host_restored=false
target_staging_dir=''

log() {
	printf '%s\n' "[honk-sdk] $*"
}

cache_link() {
	local target=$1 cached=$2
	mkdir -p "$cached"
	rm -rf "$target"
	ln -s "$cached" "$target"
}

configure_cache() {
	[ -n "$sdk_cache_dir" ] || return 0
	case "$sdk_cache_dir" in
		/*) ;;
		*) printf '%s\n' 'SDK_CACHE_DIR must be an absolute path' >&2; exit 64 ;;
	esac
	mkdir -p "$sdk_cache_dir"/{cargo,rustup,dl,rust-feed,tool-downloads,sccache,rust-host}
	cache_link "$CARGO_HOME" "$sdk_cache_dir/cargo"
	cache_link "$RUSTUP_HOME" "$sdk_cache_dir/rustup"
	cache_link "$PWD/dl" "$sdk_cache_dir/dl"
	export SCCACHE_DIR="$sdk_cache_dir/sccache"
	export SCCACHE_CACHE_SIZE="$sccache_cache_size"
	cache_enabled=true
	log "toolchain cache enabled at $sdk_cache_dir"
}

prepare_rust_feed() {
	local rust_feed_dir=feeds/packages/lang/rust
	if "$cache_enabled"; then
		local cached_feed="$sdk_cache_dir/rust-feed"
		if ! git -C "$cached_feed" cat-file -e "$rust_feed_commit^{commit}" 2>/dev/null; then
			rm -rf "$cached_feed"
			git clone --quiet https://github.com/sbwml/packages_lang_rust.git "$cached_feed"
			git -C "$cached_feed" fetch --quiet --depth=1 origin "$rust_feed_commit"
		fi
		git -C "$cached_feed" checkout --quiet --detach --force "$rust_feed_commit"
		rm -rf "$rust_feed_dir"
		ln -s "$cached_feed" "$rust_feed_dir"
		log "Rust feed restored at $rust_feed_commit"
		return 0
	fi
	rm -rf "$rust_feed_dir"
	git clone --quiet https://github.com/sbwml/packages_lang_rust.git "$rust_feed_dir"
	git -C "$rust_feed_dir" checkout --quiet --detach "$rust_feed_commit"
}

find_target_staging_dir() {
	local targets=()
	mapfile -t targets < <(find "$PWD/staging_dir" -mindepth 1 -maxdepth 1 -type d -name 'target-*' -printf '%p\n' | sort)
	if [ "${#targets[@]}" -ne 1 ]; then
		log "skipping Rust host cache: expected one target staging directory, found ${#targets[@]}"
		return 0
	fi
	target_staging_dir=${targets[0]}
}

restore_rust_host() {
	"$cache_enabled" || return 0
	find_target_staging_dir
	[ -n "$target_staging_dir" ] || return 0
	local target_name cache_host cache_stamp
	target_name=$(basename "$target_staging_dir")
	cache_host="$sdk_cache_dir/rust-host/$target_name"
	cache_stamp="$sdk_cache_dir/rust-host/$target_name.rust-installed"
	if [ -x "$cache_host/bin/rustc" ] && [ -f "$cache_host/lib/rustlib/manifest-rustc" ] && [ -f "$cache_stamp" ]; then
		rm -rf "$target_staging_dir/host"
		ln -s "$cache_host" "$target_staging_dir/host"
		mkdir -p "$PWD/staging_dir/hostpkg/stamp"
		cp "$cache_stamp" "$PWD/staging_dir/hostpkg/stamp/.rust_installed"
		rust_host_restored=true
		log "Rust host toolchain restored for $target_name"
	else
		log "Rust host toolchain cache miss for $target_name"
	fi
}

persist_rust_host() {
	"$cache_enabled" || return 0
	"$rust_host_restored" && return 0
	[ -n "$target_staging_dir" ] || return 0
	local target_name cache_host cache_stamp temporary
	target_name=$(basename "$target_staging_dir")
	cache_host="$sdk_cache_dir/rust-host/$target_name"
	cache_stamp="$sdk_cache_dir/rust-host/$target_name.rust-installed"
	if [ ! -x "$target_staging_dir/host/bin/rustc" ] || [ ! -f "$target_staging_dir/host/lib/rustlib/manifest-rustc" ] || [ ! -f "$PWD/staging_dir/hostpkg/stamp/.rust_installed" ]; then
		log "Rust host toolchain was not complete; not saving cache"
		return 0
	fi
	temporary=$(mktemp -d "$sdk_cache_dir/rust-host/.${target_name}.tmp.XXXXXX")
	cp -a "$target_staging_dir/host/." "$temporary/"
	rm -rf "$cache_host"
	mv "$temporary" "$cache_host"
	cp "$PWD/staging_dir/hostpkg/stamp/.rust_installed" "$cache_stamp"
	log "Rust host toolchain saved for $target_name"
}

ensure_sccache() {
	local archive temporary extracted
	mkdir -p "$CARGO_HOME/bin"
	archive="$linker_cache_dir/sccache-v${sccache_version}-x86_64-unknown-linux-musl.tar.gz"
	if [ ! -f "$archive" ]; then
		temporary=$(mktemp "$linker_cache_dir/.sccache.XXXXXX")
		curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
			--location --retry 5 --retry-all-errors --retry-delay 2 \
			--output "$temporary" \
			"https://github.com/mozilla/sccache/releases/download/v${sccache_version}/sccache-v${sccache_version}-x86_64-unknown-linux-musl.tar.gz"
		mv "$temporary" "$archive"
	fi
	printf '%s  %s\n' "$sccache_sha256" "$archive" | sha256sum -c -
	if ! command -v sccache >/dev/null 2>&1 || ! sccache --version 2>/dev/null | grep -Fq "$sccache_version"; then
		extracted=$(mktemp -d "$linker_cache_dir/.sccache-extract.XXXXXX")
		tar -xzf "$archive" -C "$extracted"
		install -m 0755 "$extracted/sccache-v${sccache_version}-x86_64-unknown-linux-musl/sccache" "$CARGO_HOME/bin/sccache"
		rm -rf "$extracted"
	fi
	sccache --version
}

cd /builder

# Snapshot SDK images download their SDK payload on first use.
if [ -f setup.sh ]; then
	bash setup.sh
fi

export HOME=/builder
export CARGO_HOME="$HOME/.cargo"
export RUSTUP_HOME="$HOME/.rustup"
export PATH="$CARGO_HOME/bin:$PATH"

configure_cache

if ! command -v rustup >/dev/null 2>&1; then
	curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
		--location --retry 5 --retry-all-errors --retry-delay 2 \
		https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
fi
if rustup run "$bpf_toolchain" rustc --version >/dev/null 2>&1 && rustup component list --toolchain "$bpf_toolchain" --installed | grep -q '^rust-src'; then
	log "Rust nightly $bpf_toolchain restored"
else
	rustup toolchain install "$bpf_toolchain" --profile minimal --component rust-src
fi

mkdir -p "$CARGO_HOME/bin"
linker_cache_dir=${sdk_cache_dir:+$sdk_cache_dir/tool-downloads}
if [ -z "$linker_cache_dir" ]; then linker_cache_dir=$(mktemp -d); fi
linker_archive="$linker_cache_dir/bpf-linker-${bpf_linker_version}-x86_64-unknown-linux-musl.tar.zst"
cleanup() {
	if [ -z "$sdk_cache_dir" ]; then rm -rf "$linker_cache_dir"; fi
}
trap cleanup EXIT INT TERM
if [ ! -f "$linker_archive" ]; then
	temporary_archive=$(mktemp "$linker_cache_dir/.bpf-linker.XXXXXX")
	curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
		--location --retry 5 --retry-all-errors --retry-delay 2 \
		--output "$temporary_archive" \
		"https://github.com/aya-rs/bpf-linker/releases/download/v${bpf_linker_version}/bpf-linker-x86_64-unknown-linux-musl.tar.zst"
	mv "$temporary_archive" "$linker_archive"
fi
printf '%s  %s\n' "$bpf_linker_sha256" "$linker_archive" | sha256sum -c -
if ! bpf-linker --version 2>/dev/null | grep -Fq "$bpf_linker_version"; then
	tar --zstd -xf "$linker_archive" -C "$CARGO_HOME/bin"
fi
bpf-linker --version
ensure_sccache

sed \
	-e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
	feeds.conf.default >feeds.conf
printf 'src-link %s %s\n' "$feed_name" "$feed_dir" >>feeds.conf

./scripts/feeds update -a

# Use a pinned Rust feed so the SDK can build rust/host consistently across runs.
prepare_rust_feed

./scripts/feeds install -p "$feed_name" -f honk
./scripts/feeds install -p "$feed_name" -f luci-app-honk
./scripts/feeds install -p "$feed_name" -f luci-app-honk-legacy
if "$cache_enabled"; then
	cat >>.config <<EOF
CONFIG_RUST_SCCACHE=y
CONFIG_RUST_SCCACHE_DIR="$SCCACHE_DIR"
EOF
fi
make defconfig
restore_rust_host
make "package/honk/download" V=s
make -j"$(nproc)" CONFIG_AUTOREMOVE=y BPF_RUST_TOOLCHAIN="$bpf_toolchain" \
	"package/honk/compile" \
	"package/luci-app-honk/compile" \
	"package/luci-app-honk-legacy/compile" V=s

persist_rust_host
if "$cache_enabled"; then
	sccache --show-stats || true
fi

mkdir -p "$artifacts_dir"
cp -a bin "$artifacts_dir/"
