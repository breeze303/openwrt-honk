#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'find "$tmp" -depth -delete' EXIT INT TERM

manifest() {
	local package=$1 output=$2
	find "$repo_root/$package/luasrc" -type f -printf '%P\n' | sed -e 's#^#/usr/lib/lua/luci/#' >"$output.lua"
	find "$repo_root/$package/root" -type f -printf '/%P\n' >"$output.root"
	cat "$output.lua" "$output.root" | sort -u >"$output"
}

manifest luci-app-honk "$tmp/new"
manifest luci-app-honk-legacy "$tmp/legacy"
comm -12 "$tmp/new" "$tmp/legacy" >"$tmp/conflicts"
test ! -s "$tmp/conflicts"

grep -F 'admin/services/honk"' "$repo_root/luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json" >/dev/null
grep -F 'admin/services/honk-legacy"' "$repo_root/luci-app-honk-legacy/root/usr/share/luci/menu.d/luci-app-honk-legacy.json" >/dev/null
grep -F '/cgi-bin/luci/admin/services/honk/api' "$repo_root/luci-app-honk/ui/src/api.ts" >/dev/null
grep -F '/cgi-bin/luci/admin/services/honk-legacy/api' "$repo_root/luci-app-honk-legacy/ui/src/api.ts" >/dev/null
grep -F '/luci-static/resources/honk/app/' "$repo_root/luci-app-honk/luasrc/view/honk/dashboard.htm" >/dev/null
grep -F '/luci-static/resources/honk-legacy/app/' "$repo_root/luci-app-honk-legacy/luasrc/view/honk_legacy/dashboard.htm" >/dev/null

if rg -n 'honk_api|legacy|luci-app-honk-legacy' "$repo_root/luci-app-honk/luasrc" "$repo_root/luci-app-honk/ui/src" >/dev/null; then
	echo "new implementation references the legacy implementation" >&2
	exit 1
fi

printf 'luci-package-isolation conflicts=0 routes=isolated assets=isolated\n'
