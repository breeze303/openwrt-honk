#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
app_dir="$repo_root/luci-app-honk/root/www/luci-static/resources/honk/app"
manifest=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--app-dir) app_dir=$2; shift 2 ;;
		--manifest) manifest=$2; shift 2 ;;
		*) echo "usage: $0 [--app-dir DIR] [--manifest FILE]" >&2; exit 64 ;;
	esac
done
[ -s "$app_dir/index.html" ] || { echo "dashboard entry asset is missing" >&2; exit 1; }

assets=$(sed -nE 's/.*(src|href)="(\.\/)?(assets\/[^"?]+).*/\3/p' "$app_dir/index.html" | sort -u)
[ -n "$assets" ] || { echo "dashboard manifest has no assets" >&2; exit 1; }
while IFS= read -r asset; do
	[ -s "$app_dir/$asset" ] || { echo "missing dashboard asset: $asset" >&2; exit 1; }
done <<<"$assets"
if find "$app_dir" -type f \( -name '*.map' -o -name 'zashboard*' \) -print -quit | grep -q .; then
	echo "unexpected debug or legacy dashboard asset" >&2
	exit 1
fi
if git -C "$repo_root" ls-files | grep -E '(^|/)node_modules/' >/dev/null; then
	echo "node_modules is tracked" >&2
	exit 1
fi

if [ -n "$manifest" ]; then
	mkdir -p "$(dirname "$manifest")"
	{
		printf '{"schemaVersion":"honk.dashboard-assets.v1","entry":"index.html","assets":['
		first=true
		while IFS= read -r asset; do
			$first || printf ','
			first=false
			sha=$(sha256sum "$app_dir/$asset" | cut -d ' ' -f1)
			size=$(stat -c '%s' "$app_dir/$asset")
			jq -cn --arg path "$asset" --arg sha "$sha" --argjson size "$size" '{path:$path,sha256:$sha,size:$size}'
		done <<<"$assets"
		printf '],"ok":true}\n'
	} >"$manifest"
fi
printf 'dashboard assets checked: %s\n' "$(printf '%s\n' "$assets" | wc -l | tr -d ' ')"
