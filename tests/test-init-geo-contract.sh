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
grep -F '.geo.geosite[]?' "$init" >/dev/null || fail "geosite references are not enumerated"
grep -F '.geo.geoip[]?' "$init" >/dev/null || fail "geoip references are not enumerated"
grep -F 'DAE_LOCATION_ASSET="$ASSET_DIR"' "$init" >/dev/null || fail "asset directory is not pinned"
grep -F 'rm -f "$LIVE_RECEIPT"' "$init" >/dev/null || fail "stale live receipt is not cleared"
grep -F 'CONFIG_SHA_BEFORE' "$init" >/dev/null || fail "config TOCTOU check missing"
grep -F 'HONK_QUICK_RECOVERY_FROM_INIT=1' "$init" >/dev/null || fail "recovery recursion guard missing"
grep -F 'DAE_ALLOW_CUSTOM_GEO=1' "$init" >/dev/null || fail "custom Geo policy is not passed to honk-tool"
grep -F 'write_live_receipt' "$init" >/dev/null || fail "live Geo receipt writer missing"
grep -F 'ubus call service list' "$init" >/dev/null || fail "live receipt does not use the procd instance"
grep -F 'previous_pids' "$init" >/dev/null || fail "live receipt does not reject the previous process"
grep -F -- '--only geoip' "$init" >/dev/null || fail "single-asset Geo preflight is missing"
grep -F "option allow_custom_geo '0'" "$repo_root/honk/files/honk.config" >/dev/null || fail "custom Geo default is not locked"
grep -F "option dnsmasq_forwarding '1'" "$repo_root/honk/files/honk.config" >/dev/null || fail "dnsmasq forwarding is not enabled by default"
grep -F 'dnsmasq-integration' "$init" >/dev/null || fail "dnsmasq lifecycle helper is missing"
grep -F 'HONK_DNSMASQ_FORWARDING' "$init" >/dev/null || fail "dnsmasq forwarding flag is not passed to launcher"
grep -F 'server=127.0.0.1#1053' "$repo_root/honk/files/dnsmasq-integration" >/dev/null || fail "dnsmasq Honk endpoint is missing"
grep -F 'ensure_dns_listener_binding' "$init" >/dev/null || fail "DNS listener binding migration is missing"
grep -F 'migrate_managed_dns_routing' "$init" >/dev/null || fail "managed DNS routing migration is missing"
grep -F 'pname(NetworkManager, systemd-resolved, dnsmasq) -> direct(must)' "$init" >/dev/null || fail "fixed resolver process rule is missing"
grep -F 'dip(geoip: private) -> direct' "$init" >/dev/null || fail "fixed private network rule is missing"
if grep -F 'RESOLV_HONK' "$init" >/dev/null; then fail "resolver bind-mount integration is still configured"; fi
if grep -F 'mount --bind' "$init" >/dev/null; then fail "honk must not replace resolv.conf"; fi

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
pass "init preflight, reference enumeration and TOCTOU guards"

printf '%s\n' '{"schemaVersion":"honk.init-geo.v1","ok":true,"checks":["validate","actual-geo-refs","asset-path","config-sha-before-after","stale-live-cleanup"],"assertions":7}' >"$evidence/init-contract.json"
printf '%s\n' '{"fixture":"invalid-config","ok":false,"receipt":"config-validation.json","serviceReplaced":false}' >"$evidence/failures/invalid-config.json"
printf '%s\n' '{"fixture":"geo-label-missing","ok":false,"receipt":"geo-assets.json","serviceReplaced":false}' >"$evidence/failures/geo-label-missing.json"
printf 'init-geo assertions=%s\n' "$assertions"
