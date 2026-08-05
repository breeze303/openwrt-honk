#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fixture="$repo_root/tests/fixtures/luci-network-runner.lua"
model="$repo_root/luci-app-honk/luasrc/model/honk_network.lua"
config="$repo_root/tests/fixtures/luci-v2-config.dae"

for scenario in happy same-device no-l3 missing-wan ipv6-only; do
	HONK_NETWORK_FIXTURE="$scenario" lua "$fixture" "$model" "$config"
done

grep -F 'network.interface", "dump"' "$model" >/dev/null
grep -F 'network.device", "status"' "$model" >/dev/null
grep -F 'domain++' "$model" >/dev/null
printf 'network-discovery-v2 scenarios=5\n'
