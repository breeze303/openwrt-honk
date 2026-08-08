#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'find "$tmp" -depth -delete' EXIT INT TERM

for file in "$repo_root"/luci-app-honk/luasrc/controller/*.lua "$repo_root"/luci-app-honk/luasrc/model/*.lua; do
	luac -p "$file"
done
jq empty "$repo_root/luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json"
jq empty "$repo_root/luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json"

lua "$repo_root/tests/fixtures/luci-v2-mode-runner.lua" "$repo_root" "$repo_root/tests/fixtures/luci-v2-config.dae" "$tmp" >"$tmp/modes.log"
grep -F 'preservation=ok' "$tmp/modes.log" >/dev/null

host_tool=${HONK_HOST_TOOL:-}
if [ -z "$host_tool" ]; then
	host_tool=$(find "$repo_root/.cache/work" -type f -path '*/target/debug/honk-tool' -perm -111 -print -quit)
fi
[ -n "$host_tool" ] && [ -x "$host_tool" ]
for name in china-direct gfwlist china-proxy global; do
	"$host_tool" validate --config "$tmp/$name.dae" --json >"$tmp/$name.json"
	jq -e '.ok == true' "$tmp/$name.json" >/dev/null
done

transaction_config="$tmp/transaction.dae"
cp "$repo_root/tests/fixtures/luci-v2-config.dae" "$transaction_config"
chmod 600 "$transaction_config"
mkdir -p "$tmp/run"
for outcome in success failure conflict interfaces clear-logs; do
	cp "$repo_root/tests/fixtures/luci-v2-config.dae" "$transaction_config"
	chmod 600 "$transaction_config"
	HONK_CONFIG_PATH="$transaction_config" \
	HONK_BACKUP_PATH="$tmp/last-good" \
	HONK_RUN_DIR="$tmp/run" \
	HONK_LUCI_STATE_PATH="$tmp/run/state.json" \
	HONK_LUCI_LOCK_PATH="$tmp/run/lock" \
	HONK_TOOL_PATH="$host_tool" \
	HONK_INIT_PATH="$tmp/honk-init" \
	HONK_LOG_PATH="$tmp/honk.log" \
	HONK_HEALTH_ATTEMPTS=1 \
	lua "$repo_root/tests/fixtures/luci-v2-transaction-runner.lua" "$repo_root" "$transaction_config" "$tmp" "$outcome" >"$tmp/transaction-$outcome.log"
done
grep -F 'transaction=committed' "$tmp/transaction-success.log" >/dev/null
grep -F 'transaction=restored' "$tmp/transaction-failure.log" >/dev/null
grep -F 'transaction=conflict' "$tmp/transaction-conflict.log" >/dev/null
grep -F 'interfaces=config-returned' "$tmp/transaction-interfaces.log" >/dev/null
grep -F 'logs=cleared' "$tmp/transaction-clear-logs.log" >/dev/null
cp "$repo_root/tests/fixtures/luci-v2-config.dae" "$transaction_config"
chmod 600 "$transaction_config"
HONK_CONFIG_PATH="$transaction_config" \
HONK_BACKUP_PATH="$tmp/last-good" \
HONK_RUN_DIR="$tmp/run" \
HONK_LUCI_STATE_PATH="$tmp/run/state.json" \
HONK_LUCI_LOCK_PATH="$tmp/run/lock" \
HONK_TOOL_PATH="$host_tool" \
HONK_INIT_PATH="$tmp/honk-init" \
HONK_HEALTH_ATTEMPTS=1 \
lua "$repo_root/tests/fixtures/luci-v2-transaction-runner.lua" "$repo_root" "$transaction_config" "$tmp" clash-api >"$tmp/transaction-clash-api.log"
grep -F 'clash-api=toggle' "$tmp/transaction-clash-api.log" >/dev/null

grep -F "domain(geosite: gfw) -> honk-proxy" "$repo_root/luci-app-honk/luasrc/model/mode.lua" >/dev/null
grep -F "dip(geoip: cn) -> honk-proxy" "$repo_root/luci-app-honk/luasrc/model/mode.lua" >/dev/null
grep -F "dip(geoip: private) -> direct(must)" "$repo_root/luci-app-honk/luasrc/model/mode.lua" >/dev/null
grep -F "direct-dns" "$repo_root/luci-app-honk/luasrc/model/dns.lua" >/dev/null
grep -F "proxy-dns" "$repo_root/luci-app-honk/luasrc/model/dns.lua" >/dev/null
grep -F "ADVANCED_TAKEOVER_REQUIRED" "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
grep -F "REVISION_CONFLICT" "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
grep -F "ROLLBACK" "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
grep -F 'context.authtoken' "$repo_root/luci-app-honk/luasrc/controller/honk.lua" >/dev/null
grep -F '<%=token%>' "$repo_root/luci-app-honk/luasrc/view/honk/dashboard.htm" >/dev/null
grep -F 'encodeURIComponent(token)' "$repo_root/luci-app-honk/ui/src/api.ts" >/dev/null
grep -F 'api_refresh_subscription' "$repo_root/luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json" >/dev/null
grep -F 'function M.delay' "$repo_root/luci-app-honk/luasrc/model/node.lua" >/dev/null
grep -F 'function M.subscription_url' "$repo_root/luci-app-honk/luasrc/model/node.lua" >/dev/null
grep -F 'node.subscription_url(content, found.name)' "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
grep -F 'function M.toggle_clash_api' "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
grep -F 'api_toggle_clash_api' "$repo_root/luci-app-honk/luasrc/controller/honk.lua" >/dev/null
grep -F 'admin/services/honk/api/toggle_clash_api' "$repo_root/luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json" >/dev/null
grep -F 'toggleClashApi' "$repo_root/luci-app-honk/ui/src/api.ts" >/dev/null
grep -F 'enableClashApi' "$repo_root/luci-app-honk/ui/src/views/AdvancedView.vue" >/dev/null
grep -F 'syncNetworkOptions' "$repo_root/luci-app-honk/ui/src/views/AdvancedView.vue" >/dev/null
grep -F 'source.value = result.config' "$repo_root/luci-app-honk/ui/src/views/AdvancedView.vue" >/dev/null
grep -F "await load(result.config || '')" "$repo_root/luci-app-honk/ui/src/views/AdvancedView.vue" >/dev/null
grep -F 'role="tablist"' "$repo_root/luci-app-honk/ui/src/views/AdvancedView.vue" >/dev/null
grep -F "activeTab === 'global'" "$repo_root/luci-app-honk/ui/src/views/AdvancedView.vue" >/dev/null
grep -F 'advancedTabDiscardConfirm' "$repo_root/luci-app-honk/ui/src/views/AdvancedView.vue" >/dev/null
grep -F "window.location.hash = view === 'advanced' ? '/advanced/global'" "$repo_root/luci-app-honk/ui/src/App.vue" >/dev/null
grep -F "split('/')[0]" "$repo_root/luci-app-honk/ui/src/App.vue" >/dev/null
grep -F 'network_interfaces' "$repo_root/luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json" >/dev/null
grep -F 'apply_interfaces' "$repo_root/luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json" >/dev/null
grep -F 'clear_logs' "$repo_root/luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json" >/dev/null
grep -F 'network.interface": [ "dump" ]' "$repo_root/luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json" >/dev/null
grep -F 'network.device": [ "status" ]' "$repo_root/luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json" >/dev/null
grep -F 'luci.model.honk_network' "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
test ! -e "$repo_root/luci-app-honk/luasrc/model/network.lua"
grep -F "DIAL_MODE_INVALID" "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
grep -F "LOG_LEVEL_INVALID" "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
grep -F 'function M.clear_logs' "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
grep -F 'clearLogs' "$repo_root/luci-app-honk/ui/src/api.ts" >/dev/null
grep -F 'logLevel' "$repo_root/luci-app-honk/ui/src/views/AdvancedView.vue" >/dev/null
grep -F 'clearLogs' "$repo_root/luci-app-honk/ui/src/views/LogsView.vue" >/dev/null
grep -F 'result.config = config.read()' "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
grep -F 'interface-discovery' "$repo_root/honk/Makefile" >/dev/null
grep -F 'endpoint .. "/subscriptions"' "$repo_root/luci-app-honk/luasrc/model/node.lua" >/dev/null
grep -F 'return false, "CLASH_API_UNAVAILABLE"' "$repo_root/luci-app-honk/luasrc/model/node.lua" >/dev/null
grep -F 'function M.subscription_cache' "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
grep -F 'api_subscription_cache' "$repo_root/luci-app-honk/luasrc/controller/honk.lua" >/dev/null
grep -F 'function M.capture_runtime' "$repo_root/luci-app-honk/luasrc/model/subscription.lua" >/dev/null
grep -F 'subscription.capture_runtime' "$repo_root/luci-app-honk/luasrc/model/service.lua" >/dev/null
HONK_INIT_PATH="$tmp/honk-init" lua "$repo_root/tests/fixtures/luci-subscription-refresh-runner.lua" \
	"$repo_root" "$repo_root/tests/fixtures/luci-v2-config.dae" "$tmp/subscription-refresh.log" >"$tmp/subscription-refresh.log.out"
grep -F 'subscription-refresh=runtime-api-only' "$tmp/subscription-refresh.log.out" >/dev/null
cp "$repo_root/tests/fixtures/luci-v2-config.dae" "$transaction_config"
chmod 600 "$transaction_config"
HONK_CONFIG_PATH="$transaction_config" \
HONK_BACKUP_PATH="$tmp/last-good" \
HONK_RUN_DIR="$tmp/run" \
HONK_LUCI_STATE_PATH="$tmp/run/state.json" \
HONK_LUCI_LOCK_PATH="$tmp/run/lock" \
HONK_TOOL_PATH="$host_tool" \
HONK_INIT_PATH="$tmp/honk-init" \
HONK_SUBSCRIPTION_CACHE_DIR="$tmp/subscriptions" \
HONK_HEALTH_ATTEMPTS=1 \
lua "$repo_root/tests/fixtures/luci-v2-transaction-runner.lua" "$repo_root" "$transaction_config" "$tmp" subscription-stopped >"$tmp/subscription-stopped.log"
grep -F 'subscription-refresh=offline-cache' "$tmp/subscription-stopped.log" >/dev/null
grep -F '@click="checkAll"' "$repo_root/luci-app-honk/ui/src/views/NodesView.vue" >/dev/null
grep -F 'class="nodes-toolbar"' "$repo_root/luci-app-honk/ui/src/views/NodesView.vue" >/dev/null
grep -F 'return collapsedSubscriptions.value[subscriptionName] !== false' "$repo_root/luci-app-honk/ui/src/views/NodesView.vue" >/dev/null
grep -F 'class="subscription-group"' "$repo_root/luci-app-honk/ui/src/views/NodesView.vue" >/dev/null
grep -F 'document.documentElement.dataset.theme' "$repo_root/luci-app-honk/ui/src/App.vue" >/dev/null
grep -F 'class="page-action-menu"' "$repo_root/luci-app-honk/ui/src/App.vue" >/dev/null
grep -F '<SourcePicker' "$repo_root/luci-app-honk/ui/src/views/HomeView.vue" >/dev/null
grep -F 'Teleport to="body"' "$repo_root/luci-app-honk/ui/src/components/SourcePicker.vue" >/dev/null
grep -F 'class="source-picker-panel"' "$repo_root/luci-app-honk/ui/src/components/SourcePicker.vue" >/dev/null
grep -F 'source-picker-panel' "$repo_root/luci-app-honk/ui/src/style.css" >/dev/null
if grep -F 'service-pill' "$repo_root/luci-app-honk/ui/src/views/HomeView.vue" >/dev/null || grep -F '<span>01</span>' "$repo_root/luci-app-honk/ui/src/views/HomeView.vue" >/dev/null; then
	echo 'home view must not duplicate service state or visual step numbers' >&2
	exit 1
fi
if grep -F '<select v-model="selectedSource"' "$repo_root/luci-app-honk/ui/src/views/HomeView.vue" >/dev/null; then
	echo 'home view must use the theme-aware source picker instead of a native select' >&2
	exit 1
fi
if grep -F '@click="void ' "$repo_root/luci-app-honk/ui/src/views/NodesView.vue" >/dev/null; then
	echo 'node latency actions must invoke Vue handlers' >&2
	exit 1
fi

printf 'luci-v2 modes=4 transactions=4 preservation=ok\n'
