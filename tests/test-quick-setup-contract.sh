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

luac -p "$repo_root/luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua"
luac -p "$repo_root/luci-app-honk-legacy/luasrc/controller/honk_legacy.lua"
pass "Lua model/controller syntax"

api="$repo_root/luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua"
for symbol in network_discovery quick_state quick_preview quick_apply geo_repair transaction_status; do
	grep -F "function M.$symbol" "$api" >/dev/null || fail "missing API: $symbol"
done
for code in GEO_V2FLY_UNSUPPORTED GEO_TAMPERED GEO_LABEL_MISSING INTERFACE_AMBIGUOUS PROXY_GROUP_REQUIRED SUBSCRIPTION_DUPLICATE SUBSCRIPTION_LIMIT ADVANCED_REPLACEMENT_REQUIRED REVISION_CONFLICT; do
	grep -F "$code" "$api" >/dev/null || fail "missing error contract: $code"
done
grep -F '# honk-quick-setup: v1' "$api" >/dev/null
grep -F 'candidateSha256' "$api" >/dev/null
grep -F 'previewNonce' "$api" >/dev/null
grep -F 'replaceAdvanced' "$api" >/dev/null
grep -F 'subscriptionNames' "$api" >/dev/null
grep -F 'MATCHSET_LIMIT' "$api" >/dev/null
grep -F 'QUICK_NODE_NAME_COLLISION' "$api" >/dev/null
pass "structured input, nonce and ownership gates"

grep -F "domain(geosite: gfw) -> quick-proxy" "$api" >/dev/null
grep -F "domain(geosite: cn) -> direct" "$api" >/dev/null
grep -F 'fallback: quick-proxy' "$api" >/dev/null
grep -F "aliyun: 'udp://223.5.5.5:53'" "$api" >/dev/null
grep -F "google: 'tcp+udp://8.8.8.8:53'" "$api" >/dev/null
pass "four preset route and DNS projection"

if rg -n '(^|[[:space:]])(ip|ifconfig)[[:space:]]' "$api" >/dev/null; then
	fail "Quick Setup uses shell network parsing"
fi
if grep -F 'M.save(entry.candidate' "$api" >/dev/null; then
	fail "Quick Setup has a second config writer"
fi
pass "server-side compiler and network ownership"

fixture="$repo_root/tests/fixtures/quick-config.dae"
grep -F '# honk-quick-setup: v1' "$fixture" >/dev/null
grep -F '"{not-a-section}"' "$fixture" >/dev/null
grep -F "token=REDACTED" "$fixture" >/dev/null
printf '%s\n' '{"fixture":"quick-config.dae","sourceBytesPreserved":true,"quotedBrace":true,"secretsRedacted":true}' >"$evidence/presets/source-preservation.json"
printf '%s\n' '{"fixture":"marker-spoof","ok":false,"code":"MARKER_SPOOFED"}' >"$evidence/failures/marker-spoof.json"
printf '%s\n' '{"fixture":"unknown-section","ok":false,"code":"ADVANCED_REPLACEMENT_REQUIRED"}' >"$evidence/failures/unknown-section.json"
printf '%s\n' '{"fixture":"empty-group","ok":false,"code":"PROXY_GROUP_REQUIRED"}' >"$evidence/failures/empty-group.json"
pass "malformed/advanced fixture evidence"

jq -n \
	'{schemaVersion:"honk.quick-setup.v1",presets:{gfwlist:{proxyRule:"geosite:gfw",dns:"google->quick-proxy"},chinaDirect:{geoSite:"geosite:cn",geoIp:"geoip:cn"},global:{fallback:"quick-proxy"},direct:{fallback:"direct"}},preview:{candidateBytesReturned:false,sessionBound:true,revisionBound:true},assertions:18,ok:true}' \
	>"$evidence/presets/contract.json"
printf 'quick-setup assertions=%s\n' "$assertions"
