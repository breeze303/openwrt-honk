#!/usr/bin/env bash
set -euo pipefail
set +x

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
plan=/home/breeze/honk-dev/.omo/plans/honk-openwrt-daemon-luci.md
tmp=$(mktemp -d)
assertions=0

cleanup_dir=''
cleanup() {
	if [ -n "$cleanup_dir" ] && [ -d "$cleanup_dir" ]; then
		sh "$repo_root/.github/scripts/quarantine-or-delete.sh" --dir "$cleanup_dir" --evidence "$tmp/evidence" --allowlist-json "$repo_root/tests/fixtures/secret-free-allowlist.json" >/dev/null
	fi
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

non_tmp=$(mktemp -d /tmp/honk-secret.XXXXXX)
exec 9<"$plan"
must_fail non-tmpfs "$repo_root/.github/scripts/provision-lab-secrets.sh" --plan-fd 9 --out-dir "$non_tmp" --json
exec 9<&-
rm -rf "$non_tmp"

cleanup_dir=$(mktemp -d /dev/shm/honk-secret.XXXXXX)
exec 9<"$repo_root/tests/fixtures/plan-malformed-marker.txt"
must_fail malformed-marker "$repo_root/.github/scripts/provision-lab-secrets.sh" --plan-fd 9 --out-dir "$cleanup_dir" --json
exec 9<&-
rm -rf "$cleanup_dir"
cleanup_dir=''

cleanup_dir=$(mktemp -d /dev/shm/honk-secret.XXXXXX)
exec 9<"$plan"
while IFS= read -r ignored <&9; do :; done
must_fail consumed-fd "$repo_root/.github/scripts/provision-lab-secrets.sh" --plan-fd 9 --out-dir "$cleanup_dir" --json
exec 9<&-
rm -rf "$cleanup_dir"
cleanup_dir=''

cleanup_dir=$(mktemp -d /dev/shm/honk-secret.XXXXXX)
: >"$cleanup_dir/known-hosts"
chmod 400 "$cleanup_dir/known-hosts"
exec 9<"$plan"
must_fail read-only-known-hosts "$repo_root/.github/scripts/provision-lab-secrets.sh" --plan-fd 9 --out-dir "$cleanup_dir" --json
exec 9<&-
rm -rf "$cleanup_dir"
cleanup_dir=''

cleanup_dir=$(mktemp -d /dev/shm/honk-secret.XXXXXX)
exec 9<"$plan"
"$repo_root/.github/scripts/provision-lab-secrets.sh" --plan-fd 9 --out-dir "$cleanup_dir" --json >/dev/null
exec 3<"$cleanup_dir/ssh-secret"
for name in ssh-secret luci-credentials known-hosts storage-state transaction-state; do
	[ "$(stat -c '%a' "$cleanup_dir/$name")" = 600 ]
done
"$repo_root/.github/scripts/audit-secret-exposure.sh" --evidence "$tmp/evidence" >/dev/null
assertions=$((assertions + 2))
printf 'secret-provisioning assertions=%s\n' "$assertions"
