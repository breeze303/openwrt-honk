#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
commit=63e271065246bb68ecadf9ae53abecf748806ad3
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

cd "$repo_root"

grep -Fx "PKG_SOURCE_VERSION:=$commit" honk/source.mk >/dev/null
grep -Eq '^PKG_MIRROR_HASH:=[0-9a-f]{64}$' honk/source.mk
jq -e --arg commit "$commit" '.source.commit == $commit and (.source.patchDigests | length == 9)' locks/source.lock.json >/dev/null
while IFS=$'\t' read -r patch_path patch_sha; do
	test "$(sha256sum "$patch_path" | cut -d ' ' -f 1)" = "$patch_sha"
done < <(jq -r '.source.patchDigests[] | [.path, .sha256] | @tsv' locks/source.lock.json)

tar -xzf ".cache/dl/honk-$commit.tar.gz" -C "$tmp"
source_dir="$tmp/honk-$commit"
for patch_file in honk/patches/*.patch; do
	patch --dry-run -d "$source_dir" -p1 <"$patch_file" >/dev/null
	patch -d "$source_dir" -p1 <"$patch_file" >/dev/null
done
grep -F 'Validate(validate::ValidateArgs)' "$source_dir/crates/honk-tool/src/main.rs" >/dev/null
grep -F 'pub json: bool' "$source_dir/crates/honk-tool/src/bpf.rs" >/dev/null
grep -F 'pub sample_ms: u64' "$source_dir/crates/honk-tool/src/bpf.rs" >/dev/null
grep -F '.route("/memory", get(get_memory))' "$source_dir/crates/honk-core/src/clash_api.rs" >/dev/null
grep -F '.route("/subscriptions", get(get_subscriptions))' "$source_dir/crates/honk-core/src/clash_api.rs" >/dev/null
grep -F "subscription('my-sub')" "$source_dir/doc/configuration.en.md" >/dev/null
grep -F 'test_override_outbound_rule_mode_uses_primary_for_proxy_routes' "$source_dir/crates/honk-core/src/mode.rs" >/dev/null
grep -F 'outbound_name != "direct" && !self.global_selection.is_empty() && selection_resolvable' "$source_dir/crates/honk-core/src/mode.rs" >/dev/null

sh -n honk/files/honk.init
sh -n honk/files/honk-launcher
bash -n .github/scripts/build-packages-in-sdk.sh
bash -n .github/scripts/build-honk-binaries.sh
bash -n .github/scripts/download-honk-binaries.sh
grep -F 'BPF_RUST_TOOLCHAIN?=nightly' honk/Makefile >/dev/null
grep -F 'HONK_USE_PREBUILT' honk/Makefile >/dev/null
grep -F 'HONK_PREBUILT_DIR?=$(CURDIR)/files/bin' honk/Makefile >/dev/null
grep -F 'nightly-2026-07-27' .github/workflows/build-honk-binaries.yml >/dev/null
grep -F 'RUST_STABLE_TOOLCHAIN: 1.97.1' .github/workflows/build-honk-binaries.yml >/dev/null
grep -F 'openwrt-24.10' .github/workflows/build-packages.yml >/dev/null
grep -F 'openwrt-25.12' .github/workflows/build-packages.yml >/dev/null
grep -F 'package_ext: ipk' .github/workflows/build-packages.yml >/dev/null
grep -F 'package_ext: apk' .github/workflows/build-packages.yml >/dev/null
grep -F 'workflow_run:' .github/workflows/build-packages.yml >/dev/null
grep -F 'Download prebuilt Honk binaries' .github/workflows/build-packages.yml >/dev/null
grep -F 'package/luci-app-honk/compile' .github/scripts/build-packages-in-sdk.sh >/dev/null
grep -F -- '--profile release-musl' .github/scripts/build-honk-binaries.sh >/dev/null
grep -F 'ZIGCC_TARGET' .github/scripts/build-honk-binaries.sh >/dev/null
grep -F "grep -q 'INTERP'" .github/scripts/build-honk-binaries.sh >/dev/null
grep -F -- '--retry-all-errors' .github/scripts/download-honk-binaries.sh >/dev/null
grep -F 'honk_binaries_' .github/workflows/build-honk-binaries.yml >/dev/null
grep -F 'rust_target: aarch64-unknown-linux-musl' .github/workflows/build-honk-binaries.yml >/dev/null
grep -F 'rust_target: x86_64-unknown-linux-musl' .github/workflows/build-honk-binaries.yml >/dev/null
test "$(grep -c 'rust_target:' .github/workflows/build-honk-binaries.yml)" -eq 2
if grep -Eq 'docker run|openwrt-[0-9]' .github/workflows/build-honk-binaries.yml; then
	echo 'binary workflow must build independently from OpenWrt SDKs' >&2
	exit 1
fi
if grep -Eq 'rustup|cargo|bpf-linker|libclang' .github/scripts/build-packages-in-sdk.sh .github/workflows/build-packages.yml; then
	echo 'package workflow must only stage prebuilt Honk binaries' >&2
	exit 1
fi
grep -F 'LAUNCHER=/usr/libexec/honk/honk-launcher' honk/files/honk.init >/dev/null
grep -F '>>"$LOG_FILE" 2>&1' honk/files/honk-launcher >/dev/null
if grep -Eq 'procd_set_param (stdout|stderr)' honk/files/honk.init; then
	echo 'honk init must not forward core output to procd/logd' >&2
	exit 1
fi
luac -p luci-app-honk/luasrc/controller/honk.lua
luac -p luci-app-honk/luasrc/model/honk_api.lua
jq empty luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json
jq empty luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json
grep -F '"path": "honk/dashboard"' luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json >/dev/null
grep -F '"function": "api_dashboard_prepare"' luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json >/dev/null

grep -F 'option respawn' honk/files/honk.config >/dev/null
grep -F '/etc/honk/config.dae' honk/files/honk.init >/dev/null
grep -F 'tail -n 200 /tmp/honk/honk.log' luci-app-honk/luasrc/model/honk_api.lua >/dev/null
grep -F 'REVISION_CONFLICT' luci-app-honk/luasrc/model/honk_api.lua >/dev/null
grep -F 'ROLLBACK' luci-app-honk/luasrc/model/honk_api.lua >/dev/null
grep -F -- '--sample-ms 1000' luci-app-honk/luasrc/model/honk_api.lua >/dev/null
grep -F 'runtime_nodes' luci-app-honk/luasrc/controller/honk.lua >/dev/null
grep -F '/usr/share/ucode/luci/dispatcher.uc' luci-app-honk/luasrc/controller/honk.lua >/dev/null
grep -F 'function M.runtime_nodes' luci-app-honk/luasrc/model/honk_api.lua >/dev/null
grep -F 'function M.dashboard_prepare' luci-app-honk/luasrc/model/honk_api.lua >/dev/null
grep -F 'configuredNodeCount' luci-app-honk/luasrc/model/honk_api.lua >/dev/null
grep -F 'requestRules' luci-app-honk/luasrc/model/honk_api.lua >/dev/null
grep -F 'parse_dns_upstream' luci-app-honk/luasrc/model/honk_api.lua >/dev/null
grep -F 'template("honk/dashboard")' luci-app-honk/luasrc/controller/honk.lua >/dev/null
grep -F 'floating-toolbar' luci-app-honk/luasrc/view/honk/dashboard.htm >/dev/null
grep -F "external_controller: '0.0.0.0:9090'" honk/files/config.dae >/dev/null
grep -F "external_ui: '/www/luci-static/resources/honk/app'" honk/files/config.dae >/dev/null
grep -F 'local APP_DIR = "/www/luci-static/resources/honk/app"' luci-app-honk/luasrc/model/honk_api.lua >/dev/null
test -s luci-app-honk/root/www/luci-static/resources/honk/app/index.html
find luci-app-honk/root/www/luci-static/resources/honk/app/assets -type f -size +1c | grep -q .
test ! -e luci-app-honk/root/usr/share/honk/zashboard
test ! -e scripts/update-zashboard.sh
grep -F "{ id: 'overview' as const" luci-app-honk/ui/src/App.vue >/dev/null
grep -F "{ id: 'logs' as const" luci-app-honk/ui/src/App.vue >/dev/null
grep -F "runtime.service('stop')" luci-app-honk/ui/src/App.vue >/dev/null
grep -F "class ClashClient" luci-app-honk/ui/src/api.ts >/dev/null
grep -F "client.stream<TrafficFrame>('/traffic'" luci-app-honk/ui/src/composables/useRuntime.ts >/dev/null
grep -F 'dnsProtocols' luci-app-honk/ui/src/ConfigView.vue >/dev/null
grep -F 'dnsRequestFallback' luci-app-honk/ui/src/ConfigView.vue >/dev/null
grep -F 'dnsResponseFallback' luci-app-honk/ui/src/ConfigView.vue >/dev/null
grep -F 'dnsSupportsPath' luci-app-honk/ui/src/ConfigView.vue >/dev/null
grep -F 'DnsTopology' luci-app-honk/ui/src/ConfigView.vue >/dev/null
grep -F 'dns-topology-simple-groups' luci-app-honk/ui/src/components/DnsTopology.vue >/dev/null
grep -F 'editDnsFromTopology' luci-app-honk/ui/src/ConfigView.vue >/dev/null
grep -F 'expectedRunning' luci-app-honk/ui/src/composables/useRuntime.ts >/dev/null
grep -F '启动状态确认超时' luci-app-honk/ui/src/composables/useRuntime.ts >/dev/null
grep -F 'retryDelay: 400' luci-app-honk/ui/src/composables/useRuntime.ts >/dev/null

printf 'honk OpenWrt focused checks passed\n'
