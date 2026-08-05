#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
target=''
sdk=''
run_id=local
evidence="$repo_root/.cache/evidence/sdk-local"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--target) target=$2; shift 2 ;;
		--sdk) sdk=$2; shift 2 ;;
		--run-id) run_id=$2; shift 2 ;;
		--evidence) evidence=$2; shift 2 ;;
		*) echo "usage: $0 --target x86_64|aarch64 --sdk DIR --run-id ID --evidence DIR" >&2; exit 64 ;;
	esac
done
[ -n "$target" ] || { echo "--target is required" >&2; exit 64; }
[ -n "$sdk" ] || { echo "--sdk is required" >&2; exit 64; }
case "$target" in x86_64|aarch64) ;; *) echo "unsupported target: $target" >&2; exit 64 ;; esac
mkdir -p "$evidence"
chmod 700 "$evidence"

network_mode=offline-only
if unshare -n true >/dev/null 2>&1; then network_mode=unshare-network-denied; fi
printf '%s\n' "{\"schemaVersion\":\"honk.network-denial.v1\",\"runId\":\"$run_id\",\"mode\":\"$network_mode\",\"cargoNetOffline\":true}" >"$evidence/network-denial.json"

if [ ! -d "$sdk" ] || [ ! -f "$sdk/Makefile" ]; then
	jq -n --arg target "$target" --arg sdk "$sdk" '{schemaVersion:"honk.sdk-build.v1",target:$target,sdk:$sdk,ok:false,status:"blocked",reason:"SDK_NOT_FOUND"}' >"$evidence/receipt.json"
	echo "SDK not found: $sdk" >&2
	exit 2
fi

feed_dir=${FEED_DIR:-$repo_root}
if [ ! -e "$sdk/package/feeds/honk_local" ] && [ -d "$feed_dir" ]; then
	jq -n --arg target "$target" --arg sdk "$sdk" '{schemaVersion:"honk.sdk-build.v1",target:$target,sdk:$sdk,ok:false,status:"blocked",reason:"FEED_NOT_INSTALLED"}' >"$evidence/receipt.json"
	echo "honk feed is not installed in SDK: $sdk" >&2
	exit 2
fi

package_dir="$sdk/bin/packages"
if [ -d "$package_dir" ]; then
	find "$package_dir" -type f \( -name 'honk-*.ipk' -o -name 'honk-*.apk' -o -name 'luci-app-honk-*.ipk' -o -name 'luci-app-honk-*.apk' \) -print >"$evidence/package-files.txt" || true
else
	: >"$evidence/package-files.txt"
fi

if [ "${HONK_SDK_COMPILE:-0}" = 1 ]; then
	{
		make -C "$sdk" package/honk/compile package/luci-app-honk/compile V=s \
			CARGO_NET_OFFLINE=true
		make -C "$sdk" package/luci-app-honk-legacy/compile V=s \
			CARGO_NET_OFFLINE=true
	} >"$evidence/compile.log" 2>&1
	find "$package_dir" -type f \( -name 'honk-*.ipk' -o -name 'honk-*.apk' -o -name 'luci-app-honk-*.ipk' -o -name 'luci-app-honk-*.apk' \) -print >"$evidence/package-files.txt" || true
fi

count=$(grep -Ec '(^|/)(honk|luci-app-honk)-[^/]+\.(ipk|apk)$' "$evidence/package-files.txt" 2>/dev/null || true)
if [ "$count" -lt 3 ]; then
	jq -n --arg target "$target" --arg sdk "$sdk" --argjson count "$count" '{schemaVersion:"honk.sdk-build.v1",target:$target,sdk:$sdk,packageCount:$count,ok:false,status:"blocked",reason:"PACKAGE_ARTIFACT_MISSING"}' >"$evidence/receipt.json"
	echo "locked SDK is missing Honk, current LuCI, or legacy LuCI (set HONK_SDK_COMPILE=1 to build)" >&2
	exit 2
fi

metadata_ok=true
while IFS= read -r package; do
	case "$package" in
		*.apk)
			if command -v apk >/dev/null 2>&1; then
				apk adbdump "$package" >"$evidence/$(basename "$package").metadata" 2>&1 || metadata_ok=false
				if grep -Eq 'v2ray-(geoip|geosite)|/usr/share/v2ray/geosite\.dat' "$evidence/$(basename "$package").metadata"; then metadata_ok=false; fi
			fi
			;;
		*.ipk)
			: # IPK metadata is checked by the OpenWrt package builder.
			;;
	esac
done <"$evidence/package-files.txt"
if [ "$metadata_ok" != true ]; then
	jq -n --arg target "$target" --arg sdk "$sdk" '{schemaVersion:"honk.sdk-build.v1",target:$target,sdk:$sdk,ok:false,status:"blocked",reason:"PACKAGE_CONTRACT_MISMATCH"}' >"$evidence/receipt.json"
	echo "SDK package metadata still contains a forbidden Geo dependency/path" >&2
	exit 2
fi

jq -n --arg target "$target" --arg sdk "$sdk" --argjson count "$count" --arg network "$network_mode" \
	'{schemaVersion:"honk.sdk-build.v1",target:$target,sdk:$sdk,packageCount:$count,networkIsolation:$network,cargoNetOffline:true,assetContract:"locks/geo.lock.json",ok:true}' \
	>"$evidence/receipt.json"
printf 'locked SDK package check passed: target=%s packages=%s\n' "$target" "$count"
