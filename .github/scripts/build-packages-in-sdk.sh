#!/usr/bin/env bash
set -euo pipefail

readonly feed_dir=${FEED_DIR:-/feed}
readonly artifacts_dir=${ARTIFACTS_DIR:-/artifacts}
readonly feed_name=${FEED_NAME:-honk_ci}
readonly bpf_toolchain=${BPF_RUST_TOOLCHAIN:-nightly-2026-07-27}
readonly bpf_linker_version=${BPF_LINKER_VERSION:-0.10.4}
readonly bpf_linker_sha256=${BPF_LINKER_SHA256:-4dda77daab6c5f120a468e6d3ede2498f5bd47ece712172cfb7290176d93d015}
readonly rust_feed_commit=${RUST_FEED_COMMIT:-2006dff59caa09bc3bc22ffdc84df2aa1c8d0c8a}

cd /builder

# Snapshot SDK images download their SDK payload on first use.
if [ -f setup.sh ]; then
	bash setup.sh
fi

export HOME=/builder
export CARGO_HOME="$HOME/.cargo"
export RUSTUP_HOME="$HOME/.rustup"
export PATH="$CARGO_HOME/bin:$PATH"

if ! command -v rustup >/dev/null 2>&1; then
	curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
		--location --retry 5 --retry-all-errors --retry-delay 2 \
		https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
fi
rustup toolchain install "$bpf_toolchain" --profile minimal --component rust-src

linker_archive=$(mktemp)
trap 'rm -f "$linker_archive"' EXIT INT TERM
mkdir -p "$CARGO_HOME/bin"
curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
	--location --retry 5 --retry-all-errors --retry-delay 2 \
	--output "$linker_archive" \
	"https://github.com/aya-rs/bpf-linker/releases/download/v${bpf_linker_version}/bpf-linker-x86_64-unknown-linux-musl.tar.zst"
printf '%s  %s\n' "$bpf_linker_sha256" "$linker_archive" | sha256sum -c -
tar --zstd -xf "$linker_archive" -C "$CARGO_HOME/bin"
bpf-linker --version

sed \
	-e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
	feeds.conf.default >feeds.conf
printf 'src-link %s %s\n' "$feed_name" "$feed_dir" >>feeds.conf

./scripts/feeds update -a

# Use a pinned Rust feed so the SDK can build rust/host consistently across runs.
rm -rf feeds/packages/lang/rust
git clone --quiet https://github.com/sbwml/packages_lang_rust.git feeds/packages/lang/rust
git -C feeds/packages/lang/rust checkout --quiet --detach "$rust_feed_commit"

./scripts/feeds install -p "$feed_name" -f honk
./scripts/feeds install -p "$feed_name" -f luci-app-honk
./scripts/feeds install -p "$feed_name" -f luci-app-honk-legacy
make defconfig
make "package/honk/download" V=s
make -j"$(nproc)" CONFIG_AUTOREMOVE=y BPF_RUST_TOOLCHAIN="$bpf_toolchain" \
	"package/honk/compile" \
	"package/luci-app-honk/compile" \
	"package/luci-app-honk-legacy/compile" V=s

mkdir -p "$artifacts_dir"
cp -a bin "$artifacts_dir/"
