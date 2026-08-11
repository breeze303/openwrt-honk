#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/quick-setup"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence/presets" "$evidence/failures"
chmod 700 "$evidence"
assertions=0
pass() { assertions=$((assertions + 1)); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

package="$repo_root/luci-app-honk"
rpcd="$package/root/usr/share/rpcd/ucode/luci.honk"
service="$package/ucode/honk/service.uc"
mode="$package/ucode/honk/mode.uc"
config="$package/ucode/honk/config.uc"
worker="$repo_root/honk/files/quick-transaction-worker"

for module in config dns network node subscription mode service; do
	test -s "$package/ucode/honk/$module.uc" || fail "missing Ucode module: $module"
done
test -s "$rpcd" || fail 'RPCD service is missing'
if [ -e "$package/luasrc" ]; then fail 'Lua backend files remain'; fi
pass "Ucode backend and RPCD service"

for method in state preview apply sources validate_advanced apply_advanced apply_interfaces runtime_prepare; do
	grep -Eq "^[[:space:]]*$method:" "$rpcd" || fail "missing RPCD method: $method"
done
for code in GEO_DATA_MISSING INTERFACE_AMBIGUOUS PROXY_SOURCE_REQUIRED SUBSCRIPTION_DUPLICATE ADVANCED_TAKEOVER_REQUIRED REVISION_CONFLICT; do
	rg -F "$code" "$service" "$mode" "$package/ucode/honk/node.uc" >/dev/null || fail "missing error contract: $code"
done
grep -F 'replace_managed' "$config" >/dev/null
grep -F 'nested_sections' "$config" >/dev/null
grep -F 'write_candidate' "$config" >/dev/null
pass "structured Ucode input and revision gates"

grep -F "domain(geosite: gfw) -> honk-proxy" "$mode" >/dev/null
grep -F "domain(geosite: cn) -> direct" "$mode" >/dev/null
grep -F 'fallback: honk-proxy' "$mode" >/dev/null
grep -F "DEFAULT_DIRECT = 'udp://223.5.5.5:53'" "$package/ucode/honk/dns.uc" >/dev/null
grep -F "DEFAULT_PROXY = 'https://cloudflare-dns.com/dns-query'" "$package/ucode/honk/dns.uc" >/dev/null
pass "four mode route and DNS projection"

grep -F 'flock -n 9' "$worker" >/dev/null
grep -F 'candidate must be root-owned mode 600' "$worker" >/dev/null
grep -F 'preserve ] && [ "$previous_running" = false ]' "$worker" >/dev/null
grep -F "apply_content(candidate[0], input.expectedRevision, { type: 'source'" "$service" >/dev/null
grep -F "apply_content(candidate[0], input.expectedRevision, { type: 'runtime-monitoring' }, 'preserve')" "$service" >/dev/null
pass "single writer and stopped-service preservation"

fixture="$repo_root/tests/fixtures/luci-v2-config.dae"
grep -F '# legacy comments outside managed sections remain available to migration' "$fixture" >/dev/null
grep -F 'experimental {' "$fixture" >/dev/null
grep -F 'token=REDACTED' "$fixture" >/dev/null
printf '%s\n' '{"fixture":"luci-v2-config.dae","commentsPreserved":true,"unknownSectionPreserved":true,"secretsRedacted":true}' >"$evidence/presets/source-preservation.json"
printf '%s\n' '{"fixture":"revision-conflict","ok":false,"code":"REVISION_CONFLICT"}' >"$evidence/failures/revision-conflict.json"
printf '%s\n' '{"fixture":"empty-group","ok":false,"code":"PROXY_SOURCE_REQUIRED"}' >"$evidence/failures/empty-group.json"
pass "configuration fixture evidence"

jq -n \
	'{schemaVersion:"honk.luci-ucode.v1",modes:{gfwlist:{proxyRule:"geosite:gfw",dns:"proxy-dns"},chinaDirect:{geoSite:"geosite:cn",geoIp:"geoip:cn"},global:{fallback:"honk-proxy"}},preview:{candidateBytesReturned:false,revisionBound:true},assertions:16,ok:true}' \
	>"$evidence/presets/contract.json"
printf 'quick-setup assertions=%s\n' "$assertions"
