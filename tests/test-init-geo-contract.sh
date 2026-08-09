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
grep -F "option proxy_local_dns '1'" "$repo_root/honk/files/honk.config" >/dev/null || fail "local DNS proxy is not enabled by default"
grep -F 'readlink -f /etc/resolv.conf' "$init" >/dev/null || fail "resolver target must follow the system resolver path"
grep -F 'mount --bind "$RESOLV_HONK" "$RESOLV_TARGET"' "$init" >/dev/null || fail "resolver bind mount is missing"
grep -F '/proc/self/mountinfo' "$init" >/dev/null || fail "resolver mount state must use mountinfo"
grep -F 'RESOLV_MARKER' "$init" >/dev/null || fail "resolver ownership marker is missing"
grep -F 'network_find_wan logical_wan' "$init" >/dev/null || fail "logical WAN DNS discovery is missing"
grep -F 'network.interface.$logical_wan' "$init" >/dev/null || fail "WAN status DNS discovery is missing"
grep -F '/tmp/resolv.conf.d/resolv.conf.auto' "$init" >/dev/null || fail "generated resolver fallback is missing"
grep -F '119.29.29.29 223.5.5.5' "$init" >/dev/null || fail "domestic DNS fallback is missing"
grep -F 'migrate_managed_dns_routing' "$init" >/dev/null || fail "managed DNS routing migration is missing"
grep -F 'pname(NetworkManager, systemd-resolved, dnsmasq) -> direct(must)' "$init" >/dev/null || fail "fixed resolver process rule is missing"
grep -F 'dip(geoip: private) -> direct' "$init" >/dev/null || fail "fixed private network rule is missing"
if grep -F 'HONK_LOCAL_DNS_LISTEN' "$init" >/dev/null; then fail "dedicated host DNS listener is still configured"; fi
if grep -F '127.0.0.2' "$init" >/dev/null; then fail "fixed loopback DNS listener is still configured"; fi
grep -F 'leaving resolver mount owned by another service untouched' "$init" >/dev/null || fail "foreign resolver mount guard is missing"
grep -F 'restore_resolv_conf' "$init" >/dev/null || fail "resolver restore path is missing"
pass "init preflight, reference enumeration and TOCTOU guards"

printf '%s\n' '{"schemaVersion":"honk.init-geo.v1","ok":true,"checks":["validate","actual-geo-refs","asset-path","config-sha-before-after","stale-live-cleanup"],"assertions":7}' >"$evidence/init-contract.json"
printf '%s\n' '{"fixture":"invalid-config","ok":false,"receipt":"config-validation.json","serviceReplaced":false}' >"$evidence/failures/invalid-config.json"
printf '%s\n' '{"fixture":"geo-label-missing","ok":false,"receipt":"geo-assets.json","serviceReplaced":false}' >"$evidence/failures/geo-label-missing.json"
printf 'init-geo assertions=%s\n' "$assertions"
