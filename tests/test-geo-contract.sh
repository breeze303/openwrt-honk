#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/geo-contract"
if [ "${1:-}" = "--evidence" ]; then
	evidence=$2
fi
mkdir -p "$evidence/failures"
chmod 700 "$evidence"
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM
assertions=0
pass() { assertions=$((assertions + 1)); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

geo_lock="$repo_root/locks/geo.lock.json"
jq -e '
  .schemaVersion == 2 and
  .contract.activeDirectory == "/usr/share/honk" and
  .contract.runtimeDependency == false and
  (.assets | length == 2) and
  ([.assets[] | select(.provider == "LOYALSOLDIER" and .release == "202607312254" and .sha256 == "1f3a743e8e30152a870a1674792af3976361436dcb1f510a43c499d430f6b13f" and .size == 10540162 and .labels == ["gfw","cn","private"])] | length == 1) and
  ([.assets[] | select(.provider == "V2FLY" and .release == "202607171233" and .sha256 == "b71d1999439dde2de2d2b6844a2befa50c50211ff739785c005ca7c230a17d6a" and .size == 22765206 and (.architectures | sort == ["aarch64","x86_64"]))] | length == 1) and
  ([.contract.neverTouch[]] | index("/usr/share/v2ray/geosite.dat")) != null
' "$geo_lock" >/dev/null || fail "geo lock content"
pass "geo lock release/hash/license contract"

site=$(jq -er '.assets[] | select(.kind == "geosite") | .cachePath' "$geo_lock")
ip=$(jq -er '.assets[] | select(.kind == "geoip") | .cachePath' "$geo_lock")
site_sha=$(jq -er '.assets[] | select(.kind == "geosite") | .sha256' "$geo_lock")
ip_sha=$(jq -er '.assets[] | select(.kind == "geoip") | .sha256' "$geo_lock")
site_size=$(jq -er '.assets[] | select(.kind == "geosite") | .size' "$geo_lock")
ip_size=$(jq -er '.assets[] | select(.kind == "geoip") | .size' "$geo_lock")
[ "$(stat -c '%s' "$repo_root/$site")" = "$site_size" ] || fail "geosite size"
[ "$(sha256sum "$repo_root/$site" | cut -d ' ' -f1)" = "$site_sha" ] || fail "geosite hash"
[ "$(stat -c '%s' "$repo_root/$ip")" = "$ip_size" ] || fail "geoip size"
[ "$(sha256sum "$repo_root/$ip" | cut -d ' ' -f1)" = "$ip_sha" ] || fail "geoip hash"
pass "cached payload hashes and sizes"

install_root="$tmp/root"
mkdir -p "$install_root/usr/lib/honk" "$install_root/usr/share/honk" "$install_root/usr/share/v2ray"
cp "$repo_root/$site" "$install_root/usr/lib/honk/geosite.dat"
cp "$repo_root/$ip" "$install_root/usr/lib/honk/geoip.dat"
ln -s /usr/lib/honk/geosite.dat "$install_root/usr/share/honk/geosite.dat"
ln -s /usr/lib/honk/geoip.dat "$install_root/usr/share/honk/geoip.dat"
printf 'user-owned-v2ray-fixture\n' >"$install_root/usr/share/v2ray/geosite.dat"
v2ray_hash=$(sha256sum "$install_root/usr/share/v2ray/geosite.dat" | cut -d ' ' -f1)
[ "$(readlink "$install_root/usr/share/honk/geosite.dat")" = /usr/lib/honk/geosite.dat ] || fail "geosite symlink target"
[ "$(readlink "$install_root/usr/share/honk/geoip.dat")" = /usr/lib/honk/geoip.dat ] || fail "geoip symlink target"
[ "$(sha256sum "$install_root/usr/lib/honk/geosite.dat" | cut -d ' ' -f1)" = "$site_sha" ] || fail "staged geosite hash"
[ "$(sha256sum "$install_root/usr/lib/honk/geoip.dat" | cut -d ' ' -f1)" = "$ip_sha" ] || fail "staged geoip hash"
[ "$(sha256sum "$install_root/usr/share/v2ray/geosite.dat" | cut -d ' ' -f1)" = "$v2ray_hash" ] || fail "v2ray fixture was touched"
pass "Honk-owned install root and never-touch path"

stage="$tmp/stage"
"$repo_root/.github/scripts/provision-locks.sh" --lock-dir "$repo_root/locks" --dl-dir "$repo_root/.cache/dl" --stage-dir "$stage" --check >/dev/null 2>&1 || fail "lock provision staging"
[ "$(stat -c '%a' "$stage/$(basename "$site")")" = 444 ] || fail "staged geosite mode"
[ "$(stat -c '%a' "$stage/$(basename "$ip")")" = 444 ] || fail "staged geoip mode"
pass "offline lock provision staging"

bad_dl="$tmp/bad-dl"
mkdir -p "$bad_dl"
cp "$repo_root/$site" "$bad_dl/$(basename "$site")"
cp "$repo_root/$ip" "$bad_dl/$(basename "$ip")"
printf 'tamper' >>"$bad_dl/$(basename "$site")"
if "$repo_root/.github/scripts/provision-locks.sh" --lock-dir "$repo_root/locks" --dl-dir "$bad_dl" --check >/dev/null 2>&1; then
	fail "tampered geo cache unexpectedly passed"
fi
printf '%s\n' '{"fixture":"tampered-geosite","ok":false,"code":"GEO_HASH_MISMATCH"}' >"$evidence/failures/tampered-geosite.json"
pass "tampered GeoSite rejected"

if rg -n 'v2ray-(geoip|geosite)|v2ray/geo(site|ip)' honk/Makefile honk/files/honk.init >/dev/null; then
	fail "runtime V2Fly dependency or path remains"
fi
grep -F 'DAE_LOCATION_ASSET' honk/files/honk.init >/dev/null || fail "asset environment missing"
grep -F '/usr/share/honk/geo.lock.json' honk/Makefile >/dev/null || fail "installed lock missing"
pass "package runtime dependency and path checks"

jq -n --arg site "$site_sha" --arg ip "$ip_sha" --arg v2 "$v2ray_hash" \
	'{schemaVersion:"honk.geo-install.v1",ok:true,provider:"LOYALSOLDIER",geositeSha256:$site,geoipSha256:$ip,symlinks:{geosite:"/usr/lib/honk/geosite.dat",geoip:"/usr/lib/honk/geoip.dat"},neverTouch:{path:"/usr/share/v2ray/geosite.dat",sha256:$v2},assertions:11}' \
	>"$evidence/install-contract.json"
printf 'geo-contract assertions=%s\n' "$assertions"
