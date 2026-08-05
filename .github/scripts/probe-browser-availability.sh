#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
evidence="$repo_root/.cache/evidence/browser-probe"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence"
chmod 700 "$evidence"

playwright_bin=false
playwright_node=false
playwright_test_node=false
browser_archive=false
playwright_version=
if command -v playwright >/dev/null 2>&1; then
	playwright_bin=true
	playwright_version=$(playwright --version 2>/dev/null || true)
fi
if node -e 'require.resolve("playwright")' >/dev/null 2>&1; then playwright_node=true; fi
if node -e 'require.resolve("@playwright/test")' >/dev/null 2>&1; then playwright_test_node=true; fi
if [ -d "$repo_root/.cache/dl/browser" ] || [ -f "$repo_root/.cache/dl/browser.tar.gz" ]; then browser_archive=true; fi

set +e
NPM_CONFIG_OFFLINE=true npm_config_offline=true npm exec --offline -- playwright --version >"$evidence/npm-exec.log" 2>&1
npm_rc=$?
set -e
if [ "$npm_rc" -eq 0 ] && [ -z "$playwright_version" ]; then playwright_version=$(sed -n '1p' "$evidence/npm-exec.log"); fi

available=false
[ "$playwright_bin" = true ] || [ "$playwright_node" = true ] || [ "$playwright_test_node" = true ] && available=true
status=blocked
reason=PLAYWRIGHT_NOT_PROVISIONED
[ "$available" = true ] && status=probe-only && reason=PLAYWRIGHT_RUNNER_REQUIRES_FIXTURE
jq -n \
	--arg status "$status" --arg reason "$reason" --arg version "$playwright_version" --argjson bin "$playwright_bin" --argjson node "$playwright_node" --argjson testNode "$playwright_test_node" --argjson archive "$browser_archive" --argjson npmRc "$npm_rc" \
	'{schemaVersion:"honk.browser-probe.v1",status:$status,ok:false,reason:$reason,runner:{playwrightBinary:$bin,playwrightNode:$node,playwrightTestNode:$testNode,offlineBrowserArchive:$archive,version:$version,npmExecRc:$npmRc},viewports:[375,768,1280],screenshots:0,accessibilityRuns:0,networkIsolation:"offline-only"}' \
	>"$evidence/probe.json"
cat "$evidence/probe.json"
[ "$available" = true ] && exit 2
exit 2
