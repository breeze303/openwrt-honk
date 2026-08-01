#!/usr/bin/env bash
set -euo pipefail

readonly feed_dir=${FEED_DIR:-/feed}
readonly artifacts_dir=${ARTIFACTS_DIR:-/artifacts}
readonly feed_name=${FEED_NAME:-honk_ci}

test -x "$feed_dir/honk/files/bin/honk-core"
test -x "$feed_dir/honk/files/bin/honk-tool"

cd /builder

# Snapshot SDK images download their SDK payload on first use.
if [ -f setup.sh ]; then
	bash setup.sh
fi

sed \
	-e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
	-e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
	feeds.conf.default >feeds.conf
printf 'src-link %s %s\n' "$feed_name" "$feed_dir" >>feeds.conf

./scripts/feeds update -a
./scripts/feeds install -p "$feed_name" -f luci-app-honk
make defconfig
make "package/luci-app-honk/download" V=s
make \
	-j"$(nproc)" \
	CONFIG_AUTOREMOVE=y \
	"package/luci-app-honk/compile" V=s

mkdir -p "$artifacts_dir"
cp -a bin "$artifacts_dir/"
