#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/dnsmasq-integration"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence/failures"
chmod 700 "$evidence"
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM
assertions=0
pass() { assertions=$((assertions + 1)); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

fake_bin="$tmp/bin"
run_dir="$tmp/run"
conf_dir="$tmp/dnsmasq"
mkdir -p "$fake_bin" "$run_dir" "$conf_dir"
cat >"$fake_bin/uci" <<'SH'
#!/bin/sh
case "${1:-}" in
	-q)
		case "${2:-}" in
			show) printf '%s\n' 'dhcp.cfg01=dnsmasq' ;;
			get) printf '%s\n' "${HONK_DNSMASQ_TEST_CONFDIR:?}" ;;
		esac
		;;
esac
SH
cat >"$fake_bin/dnsmasq-init" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >>"${HONK_DNSMASQ_TEST_RESTART_LOG:?}"
exit 0
SH
cat >"$fake_bin/logger" <<'SH'
#!/bin/sh
exit 0
SH
chmod 700 "$fake_bin"/*

restart_log="$tmp/dnsmasq-restarts.log"
helper="$repo_root/honk/files/dnsmasq-integration"
run_helper() {
	PATH="$fake_bin:$PATH" \
	HONK_DNSMASQ_RUN_DIR="$run_dir" \
	HONK_DNSMASQ_INIT="$fake_bin/dnsmasq-init" \
	HONK_DNSMASQ_TEST_CONFDIR="$conf_dir" \
	HONK_DNSMASQ_TEST_RESTART_LOG="$restart_log" \
	sh "$helper" "$@"
}

owned_fragment="$conf_dir/90-honk.conf"
printf 'no-poll\nno-resolv\nserver=127.0.0.1#1053\n' >"$owned_fragment"
run_helper disable
[ ! -e "$owned_fragment" ] || fail "orphaned Honk dnsmasq fragment remained"
[ ! -e "$run_dir/dnsmasq-forwarding.json" ] || fail "orphaned state file remained"
grep -qx restart "$restart_log" || fail "dnsmasq was not restarted after orphan cleanup"
pass "orphaned Honk fragment is removed without state"

: >"$restart_log"
printf 'server=127.0.0.1#5353\n' >"$owned_fragment"
run_helper disable
[ -f "$owned_fragment" ] || fail "non-Honk dnsmasq fragment was removed"
[ ! -s "$restart_log" ] || fail "dnsmasq restarted for a preserved fragment"
pass "non-Honk fragment is preserved"

: >"$restart_log"
printf 'no-poll\nno-resolv\nserver=127.0.0.1#1053\n' >"$owned_fragment"
printf '{"schemaVersion":"honk.dnsmasq.v1","owner":"fixture","endpoint":"127.0.0.1#1053","confDir":"%s","active":true}\n' "$conf_dir" >"$run_dir/dnsmasq-forwarding.json"
run_helper disable fixture
[ ! -e "$owned_fragment" ] || fail "owned dnsmasq fragment remained"
[ ! -e "$run_dir/dnsmasq-forwarding.json" ] || fail "owned dnsmasq state remained"
grep -qx restart "$restart_log" || fail "dnsmasq was not restarted after owned cleanup"
pass "owned fragment and state are removed"

printf '%s\n' '{"schemaVersion":"honk.dnsmasq-integration.v1","ok":true,"orphanCleanup":true,"foreignFragmentPreserved":true,"assertions":9}' >"$evidence/dnsmasq-contract.json"
printf 'dnsmasq-integration assertions=%s\n' "$assertions"
