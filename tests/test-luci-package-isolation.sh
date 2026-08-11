#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
package="$repo_root/luci-app-honk"
tmp=$(mktemp -d)
trap 'find "$tmp" -depth -delete' EXIT INT TERM

mapfile -t packages < <(find "$repo_root" -mindepth 1 -maxdepth 1 -type d -name 'luci-app-honk*' -printf '%f\n' | sort)
test "${#packages[@]}" -eq 1
test "${packages[0]}" = 'luci-app-honk'

find "$package/ucode" -type f -printf '%P\n' | sed -e 's#^#/usr/share/ucode/luci/#' | sort >"$tmp/modules"
find "$package/root" -type f -printf '/%P\n' | sort >"$tmp/root"
sort -u "$tmp/modules" "$tmp/root" >"$tmp/manifest"
if sort "$tmp/manifest" | uniq -d | grep -q .; then
	echo 'new package contains duplicate install paths' >&2
	exit 1
fi

grep -Fx '/usr/share/ucode/luci/honk/config.uc' "$tmp/manifest" >/dev/null
grep -Fx '/usr/share/rpcd/ucode/luci.honk' "$tmp/manifest" >/dev/null
grep -Fx '/usr/share/luci/menu.d/luci-app-honk.json' "$tmp/manifest" >/dev/null
grep -Fx '/www/luci-static/resources/honk/app/index.html' "$tmp/manifest" >/dev/null
grep -F 'admin/services/honk"' "$package/root/usr/share/luci/menu.d/luci-app-honk.json" >/dev/null
grep -F '/luci-static/resources/honk/app/index.html' "$package/htdocs/luci-static/resources/view/honk/dashboard.js" >/dev/null

if [ -e "$package/luasrc" ]; then
	echo 'new package still ships Lua backend files' >&2
	exit 1
fi
if rg -n '/cgi-bin/luci/admin/services/honk/api|honk[-_]legacy|luci-compat|luci-lua-runtime' "$package/Makefile" "$package/ucode" "$package/htdocs" "$package/ui/src" "$package/root" >/dev/null; then
	echo 'removed package or legacy transport references remain' >&2
	exit 1
fi

printf 'luci-package-isolation active=1 ucode=7 routes=native assets=isolated\n'
