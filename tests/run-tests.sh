#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
commit=$(jq -er '.source.commit' "$repo_root/locks/source.lock.json")
archive_path=$(jq -er '.source.archive.offlinePath' "$repo_root/locks/source.lock.json")
source_top=$(jq -er '.source.archive.topLevelDirectory' "$repo_root/locks/source.lock.json")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

cd "$repo_root"

grep -Fx "PKG_SOURCE_VERSION:=$commit" honk/source.mk >/dev/null
grep -Eq '^PKG_MIRROR_HASH:=[0-9a-f]{64}$' honk/source.mk
jq -e --arg commit "$commit" '.source.commit == $commit and (.source.patchDigests | length > 0)' locks/source.lock.json >/dev/null
while IFS=$'\t' read -r patch_path patch_sha; do
	test "$(sha256sum "$patch_path" | cut -d ' ' -f 1)" = "$patch_sha"
done < <(jq -r '.source.patchDigests[] | [.path, .sha256] | @tsv' locks/source.lock.json)

tar -xzf "$archive_path" -C "$tmp"
source_dir="$tmp/$source_top"
mapfile -t patch_files < <(jq -r '.source.patchDigests[].path' locks/source.lock.json)
for patch_file in "${patch_files[@]}"; do
	patch --dry-run -d "$source_dir" -p1 <"$patch_file" >/dev/null
	patch -d "$source_dir" -p1 <"$patch_file" >/dev/null
done
grep -F 'Validate(validate::ValidateArgs)' "$source_dir/crates/honk-tool/src/main.rs" >/dev/null
grep -F 'pub json: bool' "$source_dir/crates/honk-tool/src/bpf.rs" >/dev/null
grep -F 'pub sample_ms: u64' "$source_dir/crates/honk-tool/src/bpf.rs" >/dev/null
grep -F '.route("/memory", get(get_memory))' "$source_dir/crates/honk-core/src/clash_api.rs" >/dev/null
grep -F '.route("/subscriptions", get(get_subscriptions))' "$source_dir/crates/honk-core/src/clash_api.rs" >/dev/null
grep -F 'test_override_outbound_rule_mode_keeps_routing' "$source_dir/crates/honk-core/src/mode.rs" >/dev/null
if rg -n 'connect_transport_with_initial_data|wrap_transport_with_initial_data|wrap_ws_with_early_data' "$source_dir/crates"; then
	echo 'unused WebSocket early-data transport paths must not be carried by OpenWrt patches' >&2
	exit 1
fi

sh -n honk/files/honk.init
sh -n honk/files/honk-launcher
bash -n .github/scripts/build-packages-in-sdk.sh
bash -n .github/scripts/update-honk-source.sh
bash -n .github/scripts/check-dashboard-assets.sh
bash -n .github/scripts/provision-ui-cache.sh
bash -n .github/scripts/target-smoke.sh
sh -n .github/scripts/target-smoke-remote.sh
bash -n tests/quick-setup-target-harness.sh
bash -n honk/files/quick-transaction-worker
bash -n tests/test-dns-projection.sh
bash -n tests/test-luci-v2-contract.sh
bash -n tests/test-luci-package-isolation.sh
bash -n tests/test-init-geo-contract.sh
grep -F 'BPF_RUST_TOOLCHAIN?=nightly-2026-07-20' honk/Makefile >/dev/null
grep -F 'PKG_BUILD_DEPENDS:=rust/host' honk/Makefile >/dev/null
grep -F 'BPF_CARGO_CONFIG:=target.bpfel-unknown-none.rustflags=' honk/Makefile >/dev/null
grep -F -- "\$(BPF_CARGO) --config" honk/Makefile >/dev/null
grep -F 'PKG_SOURCE_URL:=https://github.com/Glassyiris/honk/archive' honk/source.mk >/dev/null
grep -F 'cargo build --locked --release' honk/Makefile >/dev/null
grep -F '+v2ray-geoip +v2ray-geosite' honk/Makefile >/dev/null
grep -F 'DAE_LOCATION_ASSET' honk/files/honk.init >/dev/null
test "$(grep -Ec '^[[:space:]]*procd_set_param env' honk/files/honk.init)" -eq 1
grep -F '"DAE_LOCATION_ASSET=$GEO_DIR"' honk/files/honk.init >/dev/null
grep -F '"HONK_DNSMASQ_FORWARDING=$dnsmasq_forwarding"' honk/files/honk.init >/dev/null
grep -F '"HONK_SUBSCRIPTION_CACHE_TTL=$SUBSCRIPTION_CACHE_TTL"' honk/files/honk.init >/dev/null
grep -F 'dnsmasq-integration' honk/Makefile >/dev/null
grep -F 'server=127.0.0.1#1053' honk/files/dnsmasq-integration >/dev/null
sh -n honk/files/dnsmasq-integration
grep -F "ls -ln " luci-app-honk/luasrc/model/service.lua >/dev/null
if grep -Fq 'stat -c %s' luci-app-honk/luasrc/model/service.lua; then
	echo 'runtime diagnostics must use BusyBox base commands' >&2
	exit 1
fi
if rg -n 'geo(site|ip)_url|allow_custom_geo' honk/files/honk.config luci-app-honk >/dev/null; then
	echo 'Geo URL settings must not be part of the Honk package contract' >&2
	exit 1
fi
grep -F 'pub fn parse_subscription_content' "$source_dir/crates/honk-core/src/subscription.rs" >/dev/null
grep -F 'openwrt-24.10' .github/workflows/build-packages.yml >/dev/null
grep -F 'openwrt-25.12' .github/workflows/build-packages.yml >/dev/null
grep -F 'package_ext: ipk' .github/workflows/build-packages.yml >/dev/null
grep -F 'package_ext: apk' .github/workflows/build-packages.yml >/dev/null
grep -F 'schedule:' .github/workflows/update-honk-source.yml >/dev/null
grep -F 'refs/heads/main' .github/workflows/update-honk-source.yml >/dev/null
grep -F 'update-honk-source.sh' .github/workflows/update-honk-source.yml >/dev/null
if rg -n 'locked Geo|loyalsoldier-geosite|v2fly-geoip' .github/workflows; then
	echo 'CI must not acquire Geo data for Honk builds' >&2
	exit 1
fi
grep -F 'package/luci-app-honk/compile' .github/scripts/build-packages-in-sdk.sh >/dev/null
grep -F 'package/honk/download' .github/scripts/build-packages-in-sdk.sh >/dev/null
grep -F 'package/honk/compile' .github/scripts/build-packages-in-sdk.sh >/dev/null
grep -F 'rustup toolchain install' .github/scripts/build-packages-in-sdk.sh >/dev/null
grep -F 'bpf-linker' .github/scripts/build-packages-in-sdk.sh >/dev/null
grep -F 'packages_lang_rust.git' .github/scripts/build-packages-in-sdk.sh >/dev/null
grep -F -- '--prefer-offline' .github/scripts/provision-ui-cache.sh >/dev/null
grep -F 'cargo fetch --locked' .github/workflows/ci.yml >/dev/null
grep -F 'cargo build --locked --manifest-path "$source_dir/Cargo.toml" -p honk-tool' .github/workflows/ci.yml >/dev/null
grep -F 'ripgrep clang llvm libclang-dev pkg-config cmake' .github/workflows/ci.yml >/dev/null
test ! -e locks/geo.lock.json
grep -F 'luci-app-honk-legacy/ui/package-lock.json --cache .cache/npm' .github/workflows/ci.yml >/dev/null
test ! -e .github/workflows/build-honk-binaries.yml
test ! -e .github/scripts/build-honk-binaries.sh
test ! -e .github/scripts/download-honk-binaries.sh
if grep -Eq 'HONK_USE_PREBUILT|HONK_PREBUILT_DIR' honk/Makefile; then
	echo 'honk package must always build from source' >&2
	exit 1
fi
if grep -Eq 'workflow_run|binary_release_tag|download-honk-binaries|Build Honk binaries' .github/workflows/build-packages.yml; then
	echo 'package workflow must not depend on binary releases' >&2
	exit 1
fi
if grep -Fq 'honk/files/bin/' .gitignore; then
	echo 'prebuilt Honk staging directory must not be part of the package contract' >&2
	exit 1
fi
grep -F 'LAUNCHER=/usr/libexec/honk/honk-launcher' honk/files/honk.init >/dev/null
grep -F '>>"$LOG_FILE" 2>&1' honk/files/honk-launcher >/dev/null
if grep -Eq 'procd_set_param (stdout|stderr)' honk/files/honk.init; then
	echo 'honk init must not forward core output to procd/logd' >&2
	exit 1
fi
for lua_file in luci-app-honk/luasrc/controller/*.lua luci-app-honk/luasrc/model/*.lua; do luac -p "$lua_file"; done
luac -p luci-app-honk-legacy/luasrc/controller/honk_legacy.lua
luac -p luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua
jq empty luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json
jq empty luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json
jq empty luci-app-honk-legacy/root/usr/share/rpcd/acl.d/luci-app-honk-legacy.json
jq empty luci-app-honk-legacy/root/usr/share/luci/menu.d/luci-app-honk-legacy.json
grep -F '"path": "honk/dashboard"' luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json >/dev/null
grep -F '"function": "api_preview"' luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json >/dev/null
grep -F '"path": "honk_legacy/dashboard"' luci-app-honk-legacy/root/usr/share/luci/menu.d/luci-app-honk-legacy.json >/dev/null
grep -F '"function": "api_dashboard_prepare"' luci-app-honk-legacy/root/usr/share/luci/menu.d/luci-app-honk-legacy.json >/dev/null

grep -F 'option respawn' honk/files/honk.config >/dev/null
grep -F '/etc/honk/config.dae' honk/files/honk.init >/dev/null
grep -F 'tail -n 200 /tmp/honk/honk.log' luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua >/dev/null
grep -F 'REVISION_CONFLICT' luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua >/dev/null
grep -F 'ROLLBACK' luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua >/dev/null
grep -F -- '--sample-ms 1000' luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua >/dev/null
grep -F 'runtime_nodes' luci-app-honk-legacy/luasrc/controller/honk_legacy.lua >/dev/null
grep -F '/usr/share/ucode/luci/dispatcher.uc' luci-app-honk-legacy/luasrc/controller/honk_legacy.lua >/dev/null
grep -F 'function M.runtime_nodes' luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua >/dev/null
grep -F 'function M.dashboard_prepare' luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua >/dev/null
grep -F 'configuredNodeCount' luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua >/dev/null
grep -F 'requestRules' luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua >/dev/null
grep -F 'parse_dns_upstream' luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua >/dev/null
grep -F 'template("honk/dashboard")' luci-app-honk/luasrc/controller/honk.lua >/dev/null
grep -F 'floating-toolbar' luci-app-honk/luasrc/view/honk/dashboard.htm >/dev/null
grep -F "external_controller: '0.0.0.0:9090'" honk/files/config.dae >/dev/null
grep -F "external_ui: '/www/luci-static/resources/honk/app'" honk/files/config.dae >/dev/null
grep -F 'local APP_DIR = "/www/luci-static/resources/honk-legacy/app"' luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua >/dev/null
test -s luci-app-honk/root/www/luci-static/resources/honk/app/index.html
find luci-app-honk/root/www/luci-static/resources/honk/app/assets -type f -size +1c | grep -q .
test -s luci-app-honk-legacy/root/www/luci-static/resources/honk-legacy/app/index.html
find luci-app-honk-legacy/root/www/luci-static/resources/honk-legacy/app/assets -type f -size +1c | grep -q .
test ! -e luci-app-honk/root/usr/share/honk/zashboard
test ! -e scripts/update-zashboard.sh
grep -F "{ id: 'overview' as const" luci-app-honk-legacy/ui/src/App.vue >/dev/null
grep -F "{ id: 'logs' as const" luci-app-honk-legacy/ui/src/App.vue >/dev/null
grep -F "runtime.service('stop')" luci-app-honk-legacy/ui/src/App.vue >/dev/null
grep -F "class ClashClient" luci-app-honk-legacy/ui/src/api.ts >/dev/null
grep -F "client.stream<TrafficFrame>('/traffic'" luci-app-honk-legacy/ui/src/composables/useRuntime.ts >/dev/null
grep -F 'dnsProtocols' luci-app-honk-legacy/ui/src/ConfigView.vue >/dev/null
grep -F 'DnsTopology' luci-app-honk-legacy/ui/src/ConfigView.vue >/dev/null
grep -F 'expectedRunning' luci-app-honk-legacy/ui/src/composables/useRuntime.ts >/dev/null
grep -F "id: 'home' as const" luci-app-honk/ui/src/App.vue >/dev/null
grep -F "id: 'diagnostics' as const" luci-app-honk/ui/src/App.vue >/dev/null
if grep -Fq 'service-controls' luci-app-honk/ui/src/views/DiagnosticsView.vue; then
	echo 'diagnostics must use the global service controls' >&2
	exit 1
fi
grep -F 'runtimeCore' luci-app-honk/ui/src/i18n.ts >/dev/null
grep -F 'geoPackage' luci-app-honk/ui/src/i18n.ts >/dev/null
grep -F 'geo-asset-grid' luci-app-honk/ui/src/views/DiagnosticsView.vue >/dev/null
grep -F "id: 'logs' as const" luci-app-honk/ui/src/App.vue >/dev/null
grep -F "china-proxy" luci-app-honk/ui/src/views/HomeView.vue >/dev/null
grep -F "ADVANCED_TAKEOVER_REQUIRED" luci-app-honk/luasrc/model/service.lua >/dev/null
grep -F "direct-dns" luci-app-honk/luasrc/model/dns.lua >/dev/null

# Behavioral contracts run from fresh disposable fixtures and keep their own
# evidence directories when the caller supplies HONK_EVIDENCE_ROOT.
evidence_root=${HONK_EVIDENCE_ROOT:-$repo_root/.cache/evidence/run-tests}
mkdir -p "$evidence_root"
bash tests/test-subscription-node-groups.sh --evidence "$evidence_root/subscription"
bash tests/test-geo-contract.sh --evidence "$evidence_root/geo"
bash tests/test-init-geo-contract.sh --evidence "$evidence_root/init-geo"
bash tests/test-network-discovery.sh --evidence "$evidence_root/network"
bash tests/test-quick-setup-contract.sh --evidence "$evidence_root/quick-contract"
bash tests/test-dns-projection.sh --evidence "$evidence_root/dns"
bash tests/test-quick-transaction.sh --evidence "$evidence_root/quick-transaction"
bash tests/test-luci-package-isolation.sh
grep -F 'pub payload_file: Option<PathBuf>' "$source_dir/crates/honk-tool/src/sub.rs" >/dev/null
grep -F 'parse_subscription_content(&sub, &content)' "$source_dir/crates/honk-tool/src/sub.rs" >/dev/null
grep -F 'SubscriptionType::Custom' "$source_dir/crates/honk-tool/src/sub.rs" >/dev/null
grep -F 'registry_mount_exists' "$source_dir/crates/honk-core/src/lib.rs" >/dev/null
grep -F 'canonical_path' "$source_dir/crates/honk-core/src/lib.rs" >/dev/null
if rg -n '^diff --git a/(crates/honk-core/src/(mode|control/connection)\.rs|crates/honk-outbound/src/proxy/transport\.rs|crates/honk-ebpf/\.cargo/config\.toml|doc/)' honk/patches; then
	echo 'OpenWrt patches contain behavior now owned by configuration or the package build' >&2
	exit 1
fi
host_tool=${HONK_HOST_TOOL:-}
if [ -z "$host_tool" ]; then
	host_tool=$(find "$repo_root/.cache/work" -type f -path '*/target/debug/honk-tool' -perm -111 -print -quit 2>/dev/null || true)
fi
if [ -z "$host_tool" ] || [ ! -x "$host_tool" ]; then
	RUSTUP_TOOLCHAIN="${HONK_TEST_RUST_TOOLCHAIN:-1.97.1}" \
		cargo build --locked --manifest-path "$source_dir/Cargo.toml" -p honk-tool
	host_tool="$source_dir/target/debug/honk-tool"
fi
HONK_HOST_TOOL="$host_tool" bash tests/test-luci-v2-contract.sh
bash tests/test-target-harness-contract.sh "$evidence_root/target-harness"
.github/scripts/check-dashboard-assets.sh --manifest "$evidence_root/assets.json"

printf 'honk OpenWrt focused checks passed\n'
