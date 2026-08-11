#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
package="$repo_root/luci-app-honk"
rpcd="$package/root/usr/share/rpcd/ucode/luci.honk"
acl="$package/root/usr/share/rpcd/acl.d/luci-app-honk.json"
menu="$package/root/usr/share/luci/menu.d/luci-app-honk.json"
view="$package/htdocs/luci-static/resources/view/honk/dashboard.js"
api="$package/ui/src/api.ts"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

jq empty "$menu"
jq empty "$acl"

if [ -e "$package/luasrc" ]; then
	fail 'Lua backend files remain in luci-app-honk'
fi
if rg -n 'luci-compat|luci-lua-runtime' "$package/Makefile" "$package/root" "$package/ucode" "$package/htdocs" >/dev/null; then
	fail 'legacy Lua runtime dependency remains'
fi

for module in config dns network node subscription mode service; do
	test -s "$package/ucode/honk/$module.uc" || fail "missing Ucode module: $module"
done
test -s "$rpcd" || fail 'missing rpcd Ucode service'
test -s "$view" || fail 'missing native LuCI dashboard view'
test -s "$repo_root/tests/fixtures/luci-honk-ucode-runner.uc" || fail 'missing Ucode fixture runner'
rg -F 'nodeNames: []' "$rpcd" >/dev/null || fail 'RPCD node list is not an array argument'
rg -F 'deviceRules: []' "$rpcd" >/dev/null || fail 'RPCD device rules are not an array argument'
rg -F 'takeover: false' "$rpcd" >/dev/null || fail 'RPCD takeover is not a Boolean argument'
rg -F 'updateInterval: 0' "$rpcd" >/dev/null || fail 'RPCD update interval is not an Integer argument'

read_methods=( state advanced default_config diagnostics logs network_interfaces runtime_dashboard )
write_methods=( preview apply service sources validate_advanced apply_advanced refresh_subscription subscription_cache delete_subscription_cache delay connectivity clear_logs toggle_clash_api reset_config apply_interfaces runtime_prepare )
for method in "${read_methods[@]}" "${write_methods[@]}"; do
	rg -q "^[[:space:]]*$method:" "$rpcd" || fail "rpcd method missing: $method"
	rg -q "method: '$method'" "$view" || fail "native view call missing: $method"
done

jq -e --argjson methods "$(printf '%s\n' "${read_methods[@]}" | jq -R . | jq -s .)" '
	.["luci-app-honk"].read.ubus["luci.honk"] as $actual |
	($actual | sort) == ($methods | sort)
' "$acl" >/dev/null || fail 'read ACL does not match RPCD methods'
jq -e --argjson methods "$(printf '%s\n' "${write_methods[@]}" | jq -R . | jq -s .)" '
	.["luci-app-honk"].write.ubus["luci.honk"] as $actual |
	($actual | sort) == ($methods | sort)
' "$acl" >/dev/null || fail 'write ACL does not match RPCD methods'
jq -e '."admin/services/honk".action == { type: "view", path: "honk/dashboard" }' "$menu" >/dev/null || fail 'menu is not a native LuCI view'

rg -F "domain(geosite: gfw) -> honk-proxy" "$package/ucode/honk/mode.uc" >/dev/null
rg -F "dip(geoip: cn) -> honk-proxy" "$package/ucode/honk/mode.uc" >/dev/null
rg -F "pname(NetworkManager, systemd-resolved, dnsmasq) -> direct(must)" "$package/ucode/honk/mode.uc" >/dev/null
rg -F "dip(geoip: private) -> direct" "$package/ucode/honk/mode.uc" >/dev/null
rg -F 'direct-dns' "$package/ucode/honk/dns.uc" >/dev/null
rg -F 'proxy-dns' "$package/ucode/honk/dns.uc" >/dev/null
rg -F 'DEFAULT_BIND' "$package/ucode/honk/dns.uc" >/dev/null
rg -F 'ADVANCED_TAKEOVER_REQUIRED' "$package/ucode/honk/service.uc" >/dev/null
rg -F 'REVISION_CONFLICT' "$package/ucode/honk/service.uc" >/dev/null
rg -F 'ROLLBACK' "$package/ucode/honk/service.uc" >/dev/null
rg -F 'wait_for_running(action !==' "$package/ucode/honk/service.uc" >/dev/null
rg -F 'subscription.capture_runtime' "$package/ucode/honk/service.uc" >/dev/null
rg -F "node.subscription_url(content, found.name)" "$package/ucode/honk/service.uc" >/dev/null
test "$(rg -F ", 'preserve');" "$package/ucode/honk/service.uc" | wc -l | tr -d ' ')" -ge 2 || fail 'preserve policy is not used for stopped-service mutations'
rg -F 'preserve ] && [ "$previous_running" = false ]' "$repo_root/honk/files/quick-transaction-worker" >/dev/null

rg -F 'honk-bridge-handshake' "$view" >/dev/null
rg -F 'honk-bridge-request' "$view" >/dev/null
rg -F 'honk-bridge-response' "$view" >/dev/null
rg -F 'AbortController' "$view" >/dev/null
rg -F 'MutationObserver' "$view" >/dev/null
rg -F 'event.source !== iframe.contentWindow' "$view" >/dev/null
rg -F 'Object.prototype.hasOwnProperty.call(calls, data.method)' "$view" >/dev/null
rg -F 'calls[data.method](...args)' "$view" >/dev/null
rg -F 'luci-*.dae' "$acl" >/dev/null
rg -F '.dae`' "$package/ucode/honk/config.uc" >/dev/null
rg -F 'valid_runtime_node_name' "$package/ucode/honk/node.uc" >/dev/null
rg -F 'honk-bridge-handshake' "$api" >/dev/null
rg -F 'honk-bridge-request' "$api" >/dev/null
rg -F 'REQUEST_TIMEOUT' "$api" >/dev/null
rg -F 'class BridgeClient' "$api" >/dev/null
if rg -q 'setInterval\([^\n]*refresh' "$package/ui/src/App.vue"; then
	fail 'dashboard must not poll state on a global timer'
fi
if rg -n '/cgi-bin/luci/admin/services/honk/api|context\.authtoken|csrf' "$api" "$view" "$package/root/www/luci-static/resources/honk/app" >/dev/null; then
	fail 'legacy HTTP API transport remains in dashboard files'
fi

rg -F "activeClient.stream<TrafficFrame>('/traffic'" "$package/ui/src/composables/useRuntimeMonitoring.ts" >/dev/null
rg -F "activeClient.stream<MemoryFrame>('/memory'" "$package/ui/src/composables/useRuntimeMonitoring.ts" >/dev/null
rg -F "id: 'traffic' as const" "$package/ui/src/App.vue" >/dev/null
rg -F "id: 'connections' as const" "$package/ui/src/App.vue" >/dev/null
rg -F 'source.value = result.config' "$package/ui/src/views/AdvancedView.vue" >/dev/null
rg -F 'clearLogs' "$package/ui/src/views/LogsView.vue" >/dev/null

host_tool=${HONK_HOST_TOOL:-}
if [ -n "$host_tool" ] && [ -x "$host_tool" ]; then
	"$host_tool" validate --config "$repo_root/tests/fixtures/luci-v2-config.dae" --json | jq -e '.ok == true' >/dev/null
fi

printf 'luci-ucode rpcd=23 bridge=v1 fixture=ucode preservation=ok\n'
