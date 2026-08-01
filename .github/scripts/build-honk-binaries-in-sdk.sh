#!/usr/bin/env bash
set -euo pipefail

readonly feed_dir=${FEED_DIR:-/feed}
readonly artifacts_dir=${ARTIFACTS_DIR:-/artifacts}
readonly feed_name=${FEED_NAME:-honk_binary_ci}
readonly bpf_toolchain=${BPF_RUST_TOOLCHAIN:-nightly-2026-07-27}
readonly rust_feed_commit=${RUST_FEED_COMMIT:-2006dff59caa09bc3bc22ffdc84df2aa1c8d0c8a}
readonly rust_target=${RUST_TARGET:?RUST_TARGET is required}

cd /builder

if [ -f setup.sh ]; then
	bash setup.sh
fi

export HOME=/builder
export CARGO_HOME="$HOME/.cargo"
export RUSTUP_HOME="$HOME/.rustup"
export PATH="$CARGO_HOME/bin:$PATH"

rustup_installer=$(mktemp)
curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
	--location --retry 5 --retry-all-errors --retry-delay 2 \
	--output "$rustup_installer" https://sh.rustup.rs
sh "$rustup_installer" -y --profile minimal --default-toolchain none
rustup toolchain install "$bpf_toolchain" --profile minimal --component rust-src
install -m 0755 "$feed_dir/.ci-tools/bpf-linker" "$CARGO_HOME/bin/bpf-linker"

sed \
	-e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
	feeds.conf.default >feeds.conf
printf 'src-link %s %s\n' "$feed_name" "$feed_dir" >>feeds.conf

./scripts/feeds update -a
rm -rf feeds/packages/lang/rust
git clone --quiet https://github.com/sbwml/packages_lang_rust.git feeds/packages/lang/rust
git -C feeds/packages/lang/rust checkout --quiet --detach "$rust_feed_commit"

./scripts/feeds install -p "$feed_name" -f honk
make defconfig
make package/honk/download V=s
make \
	-j"$(nproc)" \
	CONFIG_AUTOREMOVE= \
	BPF_RUST_TOOLCHAIN="$bpf_toolchain" \
	package/honk/compile V=s

core=$(find build_dir -type f -path "*/target/$rust_target/release/honk-core" -print -quit)
tool=$(find build_dir -type f -path "*/target/$rust_target/release/honk-tool" -print -quit)
test -n "$core" && test -x "$core"
test -n "$tool" && test -x "$tool"

mkdir -p "$artifacts_dir"
install -m 0755 "$core" "$artifacts_dir/honk-core"
install -m 0755 "$tool" "$artifacts_dir/honk-tool"
sha256sum "$artifacts_dir/honk-core" "$artifacts_dir/honk-tool"
