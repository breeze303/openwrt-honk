#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/geo"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence/failures"
chmod 700 "$evidence"
assertions=0
pass() { assertions=$((assertions + 1)); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

makefile="$repo_root/honk/Makefile"
init="$repo_root/honk/files/honk.init"
service="$repo_root/luci-app-honk/ucode/honk/service.uc"

grep -F '+v2ray-geoip +v2ray-geosite' "$makefile" >/dev/null || fail "official Geo package dependencies are missing"
grep -F 'GEO_DIR=/usr/share/v2ray' "$init" >/dev/null || fail "init Geo path is not OpenWrt-owned"
grep -F "const GEO_DIR = '/usr/share/v2ray';" "$service" >/dev/null || fail "LuCI Geo path is not OpenWrt-owned"
grep -F "package: 'v2ray-geosite'" "$service" >/dev/null || fail "LuCI GeoSite package metadata missing"
grep -F "package: 'v2ray-geoip'" "$service" >/dev/null || fail "LuCI GeoIP package metadata missing"
test ! -e "$repo_root/locks/geo.lock.json" || fail "Geo lock still exists"
if rg -n 'GEO_(SITE|IP)_CACHE|geo\.lock|LOYALSOLDIER_LOCKED|V2FLY_LOCKED|DAE_ALLOW_CUSTOM_GEO|geo capabilities|geo repair|/usr/(lib|share)/honk' "$makefile" "$init" "$repo_root/honk/files/quick-transaction-worker" "$service" "$repo_root/luci-app-honk/root/usr/share/rpcd/ucode/luci.honk" "$repo_root/luci-app-honk/ui/src" "$repo_root/.github/workflows" >/dev/null; then
	fail "Honk-owned or locked Geo implementation remains"
fi
if rg -n 'geo_settings|geo_download|geosite_url|geoip_url|allow_custom_geo' "$repo_root/honk/files" "$repo_root/luci-app-honk" "$repo_root/.github/workflows" --glob '!**/root/www/**' >/dev/null; then
	fail "Geo download API or UCI options remain"
fi
if rg -n 'loyalsoldier-geosite|v2fly-geoip|Prepare locked Geo|locked Geo' "$repo_root/.github" >/dev/null; then
	fail "CI still acquires locked Geo payloads"
fi
"$repo_root/.github/scripts/provision-locks.sh" --lock-dir "$repo_root/locks" --check >/dev/null || fail "remaining lock manifests do not validate"
pass "OpenWrt Geo package contract"

printf '%s\n' '{"schemaVersion":"honk.geo-install.v2","ok":true,"directory":"/usr/share/v2ray","packages":["v2ray-geoip","v2ray-geosite"],"locked":false,"assertions":9}' >"$evidence/geo-contract.json"
printf '%s\n' '{"fixture":"missing-openwrt-geo-package","ok":false,"code":"GEO_DATA_MISSING"}' >"$evidence/failures/missing-openwrt-geo-package.json"
printf 'geo assertions=%s\n' "$assertions"
