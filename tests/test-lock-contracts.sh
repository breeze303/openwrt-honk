#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
assertions=0

cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

must_fail() {
	local name=$1
	shift
	if "$@" >/dev/null 2>&1; then
		printf 'FAIL: %s unexpectedly succeeded\n' "$name" >&2
		return 1
	fi
	assertions=$((assertions + 1))
	printf 'PASS: %s\n' "$name"
}

"$repo_root/.github/scripts/provision-locks.sh" --lock-dir "$repo_root/locks" --dl-dir "$repo_root/.cache/dl" --check >/dev/null
assertions=$((assertions + 1))
must_fail unavailable-provider "$repo_root/.github/scripts/provision-locks.sh" --lock-dir "$repo_root/locks" --dl-dir "$repo_root/.cache/dl" --offline

cp -a "$repo_root/locks" "$tmp/locks"
jq 'del(.contract.providerPath)' "$tmp/locks/runtime-deps.lock.json" >"$tmp/replaced.json"
mv "$tmp/replaced.json" "$tmp/locks/runtime-deps.lock.json"
must_fail provider-omission "$repo_root/.github/scripts/provision-locks.sh" --lock-dir "$tmp/locks" --dl-dir "$repo_root/.cache/dl" --check

cp -a "$repo_root/locks" "$tmp/license-locks"
jq 'del(.source.license.sourceLicenseUrl)' "$tmp/license-locks/source.lock.json" >"$tmp/replaced.json"
mv "$tmp/replaced.json" "$tmp/license-locks/source.lock.json"
must_fail license-omission "$repo_root/.github/scripts/provision-locks.sh" --lock-dir "$tmp/license-locks" --dl-dir "$repo_root/.cache/dl" --check

cp -a "$repo_root/locks" "$tmp/mips-locks"
jq '.targets[0].target = "mips" | .targets[0].packageArch = "mips_24kc"' "$tmp/mips-locks/openwrt-targets.lock.json" >"$tmp/replaced.json"
mv "$tmp/replaced.json" "$tmp/mips-locks/openwrt-targets.lock.json"
must_fail mips-target "$repo_root/.github/scripts/provision-locks.sh" --lock-dir "$tmp/mips-locks" --dl-dir "$repo_root/.cache/dl" --check

cp -a "$repo_root/locks" "$tmp/qemu-locks"
jq '.contract.availability = "available" | .command = null' "$tmp/qemu-locks/qemu.lock.json" >"$tmp/replaced.json"
mv "$tmp/replaced.json" "$tmp/qemu-locks/qemu.lock.json"
must_fail qemu-mismatch "$repo_root/.github/scripts/provision-locks.sh" --lock-dir "$tmp/qemu-locks" --dl-dir "$repo_root/.cache/dl" --check

printf 'lock-contract assertions=%s\n' "$assertions"
