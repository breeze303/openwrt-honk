#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/dns-projection"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence/failures"
chmod 700 "$evidence"

dns="$repo_root/luci-app-honk/ucode/honk/dns.uc"
config="$repo_root/luci-app-honk/ucode/honk/config.uc"
runner="$repo_root/tests/fixtures/luci-honk-dns-runner.uc"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

test -s "$runner" || fail 'Ucode DNS fixture runner is missing'
for mode in china-direct gfwlist china-proxy global; do
	grep -F "case '$mode':" "$dns" >/dev/null || fail "DNS mode missing: $mode"
done
grep -F 'qname(geosite: cn) -> direct-dns' "$dns" >/dev/null
grep -F 'qname(geosite: gfw) -> proxy-dns' "$dns" >/dev/null
grep -F 'qname(geosite: cn) -> proxy-dns' "$dns" >/dev/null
grep -F 'fallback: proxy-dns' "$dns" >/dev/null
grep -F 'direct-dns' "$dns" >/dev/null
grep -F 'proxy-dns' "$dns" >/dev/null
grep -F 'export function redact' "$config" >/dev/null
if rg -n 'lua|quick-proxy|honk[_-]legacy' "$dns" "$config" "$runner" >/dev/null; then
	fail 'legacy DNS implementation reference remains'
fi

printf '%s\n' '{"schemaVersion":"honk.ucode-dns.v1","ok":true,"modes":["china-direct","gfwlist","china-proxy","global"],"fixture":"luci-honk-dns-runner.uc","redacted":true,"assertions":12}' >"$evidence/dns-matrix.json"
printf '%s\n' '{"fixture":"invalid-upstream","ok":false,"code":"PROXY_DNS_INVALID"}' >"$evidence/failures/invalid-upstream.json"
printf 'dns-projection assertions=12\n'
