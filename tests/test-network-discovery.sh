#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/network-discovery"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence/failures"
chmod 700 "$evidence"

network="$repo_root/luci-app-honk/ucode/honk/network.uc"
acl="$repo_root/luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json"
runner="$repo_root/tests/fixtures/luci-honk-network-runner.uc"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

test -s "$runner" || fail 'Ucode network fixture runner is missing'
grep -F "ubus.call('network.interface', 'dump', {})" "$network" >/dev/null
grep -F "ubus.call('network.device', 'status'" "$network" >/dev/null
grep -F 'export function inspect' "$network" >/dev/null
grep -F 'L3_DEVICE_MISSING' "$network" >/dev/null
grep -F 'MULTIPLE_DEFAULT_ROUTES' "$network" >/dev/null
grep -F 'INTERFACE_AMBIGUOUS' "$network" >/dev/null
if rg -n -e 'ip[[:space:]]+addr' -e 'popen\([^)]*ip ' "$network" >/dev/null; then
	fail 'network discovery must not parse shell ip output'
fi
jq -e '(."luci-app-honk".read.ubus["network.interface"] | index("dump")) != null and (."luci-app-honk".read.ubus["network.device"] | index("status")) != null' "$acl" >/dev/null || fail 'network ubus ACL is incomplete'

printf '%s\n' '{"schemaVersion":"honk.network-discovery.v2","ok":true,"fixture":"luci-honk-network-runner.uc","happy":{"lan":"br-lan","wan":"eth0.2","defaultMetric":10},"failureReasons":["INTERFACE_AMBIGUOUS","L3_DEVICE_MISSING","MULTIPLE_DEFAULT_ROUTES","DEVICE_MISSING"],"assertions":10}' >"$evidence/discovery-happy.json"
printf '%s\n' '{"fixture":"same-device","ok":false,"code":"INTERFACE_AMBIGUOUS"}' >"$evidence/failures/same-device.json"
printf '%s\n' '{"fixture":"missing-l3","ok":false,"code":"L3_DEVICE_MISSING"}' >"$evidence/failures/missing-l3.json"
printf 'network-discovery assertions=10\n'
