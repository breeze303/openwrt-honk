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

must_pass() {
	local name=$1
	shift
	if ! "$@" >/dev/null 2>&1; then
		printf 'FAIL: %s unexpectedly failed\n' "$name" >&2
		return 1
	fi
	assertions=$((assertions + 1))
	printf 'PASS: %s\n' "$name"
}

must_pass protected-baseline-matches "$repo_root/verify-scope.sh" --compare --baseline /home/breeze/honk-dev/.omo/evidence/honk-openwrt-daemon-luci/01/scope-baseline

fixture_root="$tmp/workspace"
for checkout in honk luci-app-dae luci-app-homeproxy passwall; do
	mkdir -p "$fixture_root/$checkout/nested"
	printf 'tracked\n' >"$fixture_root/$checkout/tracked"
	printf 'dirty-base\n' >"$fixture_root/$checkout/dirty"
	printf 'ignored\n' >"$fixture_root/$checkout/ignored"
	printf 'ignored\n' >"$fixture_root/$checkout/.gitignore"
	ln -s tracked "$fixture_root/$checkout/link"
	GIT_MASTER=1 git -C "$fixture_root/$checkout" init -q
	GIT_MASTER=1 git -C "$fixture_root/$checkout" add .
	GIT_MASTER=1 git -C "$fixture_root/$checkout" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture
	printf 'untracked\n' >"$fixture_root/$checkout/untracked"
	printf 'dirty-now\n' >"$fixture_root/$checkout/dirty"
done

"$repo_root/verify-scope.sh" --workspace "$fixture_root" --capture --out "$tmp/baseline" >/dev/null
"$repo_root/verify-scope.sh" --workspace "$fixture_root" --compare --baseline "$tmp/baseline" >/dev/null
assertions=$((assertions + 1))

printf 'changed\n' >"$fixture_root/honk/tracked"
must_fail tracked-content "$repo_root/verify-scope.sh" --workspace "$fixture_root" --compare --baseline "$tmp/baseline"
printf 'tracked\n' >"$fixture_root/honk/tracked"

printf 'changed\n' >"$fixture_root/honk/untracked"
must_fail untracked-content "$repo_root/verify-scope.sh" --workspace "$fixture_root" --compare --baseline "$tmp/baseline"
printf 'untracked\n' >"$fixture_root/honk/untracked"

printf 'changed\n' >"$fixture_root/honk/ignored"
must_fail ignored-content "$repo_root/verify-scope.sh" --workspace "$fixture_root" --compare --baseline "$tmp/baseline"
printf 'ignored\n' >"$fixture_root/honk/ignored"

rm "$fixture_root/honk/link"
ln -s dirty "$fixture_root/honk/link"
must_fail symlink-target "$repo_root/verify-scope.sh" --workspace "$fixture_root" --compare --baseline "$tmp/baseline"
rm "$fixture_root/honk/link"
ln -s tracked "$fixture_root/honk/link"

chmod 600 "$fixture_root/honk/tracked"
must_fail mode-drift "$repo_root/verify-scope.sh" --workspace "$fixture_root" --compare --baseline "$tmp/baseline"
chmod 644 "$fixture_root/honk/tracked"

printf 'changed-again\n' >"$fixture_root/honk/dirty"
must_fail pre-existing-dirty-drift "$repo_root/verify-scope.sh" --workspace "$fixture_root" --compare --baseline "$tmp/baseline"

printf 'scope assertions=%s\n' "$assertions"
