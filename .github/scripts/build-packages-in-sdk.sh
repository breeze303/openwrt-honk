#!/usr/bin/env bash
set -euo pipefail

readonly feed_dir=${FEED_DIR:-/feed}
readonly artifacts_dir=${ARTIFACTS_DIR:-/artifacts}
readonly feed_name=${FEED_NAME:-honk_ci}
readonly bpf_toolchain=${BPF_RUST_TOOLCHAIN:-nightly-2026-07-27}
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

curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
	--location https://sh.rustup.rs \
	| sh -s -- -y --profile minimal --default-toolchain none
rustup toolchain install "$bpf_toolchain" --profile minimal --component rust-src
install -m 0755 "$feed_dir/.ci-tools/bpf-linker" "$CARGO_HOME/bin/bpf-linker"
bpf-linker --version

sed \
	-e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
	feeds.conf.default >feeds.conf
printf 'src-link %s %s\n' "$feed_name" "$feed_dir" >>feeds.conf

./scripts/feeds update -a

# Honk needs a recent Rust host compiler. Use the same feed recipe as the
# reference SDK action, pinned so reruns keep the same compiler definition.
rm -rf feeds/packages/lang/rust
git clone --quiet https://github.com/sbwml/packages_lang_rust.git feeds/packages/lang/rust
git -C feeds/packages/lang/rust checkout --quiet --detach "$rust_feed_commit"

./scripts/feeds install -p "$feed_name" -f luci-app-honk
make defconfig
make "package/luci-app-honk/download" V=s
make \
	-j"$(nproc)" \
	CONFIG_AUTOREMOVE=y \
	BPF_RUST_TOOLCHAIN="$bpf_toolchain" \
	"package/luci-app-honk/compile" V=s

mkdir -p "$artifacts_dir"
cp -a bin "$artifacts_dir/"
