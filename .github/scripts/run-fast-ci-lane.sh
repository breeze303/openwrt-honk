#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
lane=a
run_id=local
evidence="$repo_root/.cache/evidence/fast-ci-$run_id"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--lane) lane=$2; shift 2 ;;
		--run-id) run_id=$2; shift 2 ;;
		--evidence) evidence=$2; shift 2 ;;
		*) echo "usage: $0 --lane a|b --run-id ID --evidence DIR" >&2; exit 64 ;;
	esac
done
case "$lane" in a|b) ;; *) echo "lane must be a or b" >&2; exit 64 ;; esac
mkdir -p "$evidence"
chmod 700 "$evidence"
home=$(mktemp -d "$repo_root/.cache/fast-home-$run_id.XXXXXX")
target=$(mktemp -d "$repo_root/.cache/fast-target-$run_id.XXXXXX")
cleanup() { rm -rf "$home" "$target"; }
trap cleanup EXIT INT TERM

network_mode=offline-only
if unshare -n true >/dev/null 2>&1; then network_mode=unshare-network-denied; fi
printf '%s\n' "{\"schemaVersion\":\"honk.network-denial.v1\",\"runId\":\"$run_id\",\"mode\":\"$network_mode\",\"cargoNetOffline\":true}" >"$evidence/network-denial.json"

run_logged() {
	local name=$1
	shift
	"$@" >"$evidence/$name.log" 2>&1
}

run_offline_logged() {
	local name=$1
	shift
	if [ "$network_mode" = unshare-network-denied ]; then
		unshare -n -- "$@" >"$evidence/$name.log" 2>&1
	else
		"$@" >"$evidence/$name.log" 2>&1
	fi
}

if [ "$lane" = a ]; then
	run_logged source-lock timeout 300 bash "$repo_root/tests/test-source-lock.sh"
	run_logged subscription-groups timeout 300 bash "$repo_root/tests/test-subscription-node-groups.sh" --evidence "$evidence/subscription"
	run_logged geo-contract timeout 300 bash "$repo_root/tests/test-geo-contract.sh" --evidence "$evidence/geo"
	run_logged init-geo timeout 60 bash "$repo_root/tests/test-init-geo-contract.sh" --evidence "$evidence/init-geo"
	run_logged network-discovery timeout 60 bash "$repo_root/tests/test-network-discovery.sh" --evidence "$evidence/network"
	run_logged quick-setup timeout 60 bash "$repo_root/tests/test-quick-setup-contract.sh" --evidence "$evidence/quick"
	run_logged dns-projection timeout 60 bash "$repo_root/tests/test-dns-projection.sh" --evidence "$evidence/dns"
	run_logged quick-transaction timeout 60 bash "$repo_root/tests/test-quick-transaction.sh" --evidence "$evidence/transaction"
else
	run_logged assets "$repo_root/.github/scripts/check-dashboard-assets.sh" --manifest "$evidence/assets.json"
	run_logged ui-cache "$repo_root/.github/scripts/provision-ui-cache.sh" --lock "$repo_root/luci-app-honk/ui/package-lock.json" --cache "$repo_root/.cache/npm" --evidence "$evidence/ui-cache.json"
	ui_env=(env "HOME=$home" "npm_config_cache=${NPM_SOURCE_CACHE:-$HOME/.npm}")
	run_offline_logged ui-ci "${ui_env[@]}" npm ci --offline --ignore-scripts --prefix "$repo_root/luci-app-honk/ui"
	run_offline_logged ui-build "${ui_env[@]}" npm run build --prefix "$repo_root/luci-app-honk/ui"
	run_logged assets-after "$repo_root/.github/scripts/check-dashboard-assets.sh" --manifest "$evidence/assets-after.json"
	run_offline_logged legacy-ui-ci "${ui_env[@]}" npm ci --offline --ignore-scripts --prefix "$repo_root/luci-app-honk-legacy/ui"
	run_offline_logged legacy-ui-build "${ui_env[@]}" npm run build --prefix "$repo_root/luci-app-honk-legacy/ui"
	run_logged legacy-assets-after "$repo_root/.github/scripts/check-dashboard-assets.sh" --app-dir "$repo_root/luci-app-honk-legacy/root/www/luci-static/resources/honk-legacy/app" --manifest "$evidence/legacy-assets-after.json"
fi

jq -n --arg lane "$lane" --arg runId "$run_id" --arg network "$network_mode" \
	'{schemaVersion:"honk.fast-ci.v1",lane:$lane,runId:$runId,networkIsolation:$network,cargoNetOffline:true,ok:true}' \
	>"$evidence/receipt.json"
printf 'fast CI lane %s passed (%s)\n' "$lane" "$network_mode"
