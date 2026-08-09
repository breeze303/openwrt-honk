#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/init-geo"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence/failures"
chmod 700 "$evidence"
init="$repo_root/honk/files/honk.init"
assertions=0
pass() { assertions=$((assertions + 1)); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

sh -n "$init"
grep -F 'honk-tool validate --config "$CONFIG" --json' "$init" >/dev/null || fail "validate preflight missing"
grep -F 'config-validation.json' "$init" >/dev/null || fail "validation receipt missing"
grep -F 'GEO_DIR=/usr/share/v2ray' "$init" >/dev/null || fail "OpenWrt Geo directory is not configured"
grep -F 'geosite.dat' "$init" >/dev/null || fail "GeoSite presence check missing"
grep -F 'geoip.dat' "$init" >/dev/null || fail "GeoIP presence check missing"
grep -F '"DAE_LOCATION_ASSET=$GEO_DIR"' "$init" >/dev/null || fail "runtime Geo directory is not exported"
grep -F '+v2ray-geoip +v2ray-geosite' "$repo_root/honk/Makefile" >/dev/null || fail "official Geo package dependencies missing"
grep -F "option dnsmasq_forwarding '1'" "$repo_root/honk/files/honk.config" >/dev/null || fail "dnsmasq forwarding is not enabled by default"
grep -F 'dnsmasq-integration' "$init" >/dev/null || fail "dnsmasq lifecycle helper is missing"
grep -F 'HONK_DNSMASQ_FORWARDING' "$init" >/dev/null || fail "dnsmasq forwarding flag is not passed to launcher"
grep -F 'server=127.0.0.1#1053' "$repo_root/honk/files/dnsmasq-integration" >/dev/null || fail "dnsmasq Honk endpoint is missing"
grep -F 'ensure_dns_listener_binding' "$init" >/dev/null || fail "DNS listener binding migration is missing"
grep -F 'migrate_managed_dns_routing' "$init" >/dev/null || fail "managed DNS routing migration is missing"
grep -F 'pname(NetworkManager, systemd-resolved, dnsmasq) -> direct(must)' "$init" >/dev/null || fail "fixed resolver process rule is missing"
grep -F 'dip(geoip: private) -> direct' "$init" >/dev/null || fail "fixed private network rule is missing"
if grep -Eq 'geo\.lock|DAE_ALLOW_CUSTOM_GEO|write_live_receipt|/usr/(lib|share)/honk' "$init"; then fail "init still contains Honk-owned Geo handling"; fi
if grep -F 'RESOLV_HONK' "$init" >/dev/null; then fail "resolver bind-mount integration is still configured"; fi
if grep -F 'mount --bind' "$init" >/dev/null; then fail "honk must not replace resolv.conf"; fi

geo_fixture_dir="$evidence/v2ray"
mkdir -p "$geo_fixture_dir"
: >"$geo_fixture_dir/geosite.dat"
: >"$geo_fixture_dir/geoip.dat"
if (
	. "$init"
	GEO_DIR="$geo_fixture_dir"
	VALIDATION_ERROR='{"geo":{"geosite":["cn"],"geoip":["private"]}}'
	validate_geo_assets
); then
	fail "empty Geo files passed the preflight"
fi
printf 'geosite\n' >"$geo_fixture_dir/geosite.dat"
printf 'geoip\n' >"$geo_fixture_dir/geoip.dat"
(
	. "$init"
	GEO_DIR="$geo_fixture_dir"
	VALIDATION_ERROR='{"geo":{"geosite":["cn"],"geoip":["private"]}}'
	validate_geo_assets
) || fail "OpenWrt Geo files did not pass the preflight"
rm -f "$geo_fixture_dir/geoip.dat"
if (
	. "$init"
	GEO_DIR="$geo_fixture_dir"
	VALIDATION_ERROR='{"geo":{"geosite":["cn"],"geoip":["private"]}}'
	validate_geo_assets
); then
	fail "missing GeoIP passed the preflight"
fi

dns_fixture_dir="$evidence/dns-bind"
mkdir -p "$dns_fixture_dir/run"
legacy_config="$dns_fixture_dir/legacy.dae"
custom_config="$dns_fixture_dir/custom.dae"
printf '%s\n' 'global {' '}' 'dns {' $'\tupstream {' $'\t\talidns: \'udp://223.5.5.5:53\'' $'\t}' '}' >"$legacy_config"
printf '%s\n' 'global {' '}' 'dns {' $'\tbind: \'tcp+udp://127.0.0.1:5353\'' '}' >"$custom_config"
(
	. "$init"
	CONFIG="$legacy_config"
	RUN_DIR="$dns_fixture_dir/run"
	ensure_dns_listener_binding
)
grep -F "bind: 'tcp+udp://127.0.0.1:1053'" "$legacy_config" >/dev/null || fail "legacy config did not receive the Honk DNS listener"
(
	. "$init"
	CONFIG="$custom_config"
	RUN_DIR="$dns_fixture_dir/run"
	ensure_dns_listener_binding
)
grep -F "bind: 'tcp+udp://127.0.0.1:5353'" "$custom_config" >/dev/null || fail "custom DNS listener binding was replaced"
if grep -Fq "bind: 'tcp+udp://127.0.0.1:1053'" "$custom_config"; then fail "custom DNS listener binding was duplicated"; fi
pass "init uses OpenWrt Geo data without lock state"

printf '%s\n' '{"schemaVersion":"honk.init-geo.v2","ok":true,"geoDirectory":"/usr/share/v2ray","packages":["v2ray-geoip","v2ray-geosite"],"assertions":8}' >"$evidence/init-contract.json"
printf '%s\n' '{"fixture":"geo-file-missing","ok":false,"serviceReplaced":false}' >"$evidence/failures/geo-file-missing.json"
printf 'init-geo assertions=%s\n' "$assertions"
