#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/quick-transaction"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence/failures"
chmod 700 "$evidence"
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM
assertions=0
pass() { assertions=$((assertions + 1)); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

config="$tmp/config.dae"
state="$tmp/state"
tool="$tmp/honk-tool"
init="$tmp/honk-init"
mkdir -p "$state"
printf 'previous-config-bytes\n' >"$config"
chmod 600 "$config"
cat >"$tool" <<'SH'
#!/bin/sh
case "${1:-}" in
  validate|geo) printf '{"ok":true}\n'; exit 0 ;;
  *) exit 64 ;;
esac
SH
cat >"$init" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >>"${HONK_QUICK_INIT_LOG:?}"
if [ "${HONK_QUICK_INIT_FAIL:-0}" = 1 ]; then exit 1; fi
if [ "$1" = restart ] && [ "${HONK_QUICK_INIT_FAIL_ONCE_FILE:-}" ]; then
	if [ ! -e "$HONK_QUICK_INIT_FAIL_ONCE_FILE" ]; then
		touch "$HONK_QUICK_INIT_FAIL_ONCE_FILE"
		exit 1
	fi
fi
exit 0
SH
chmod 700 "$tool" "$init"
export HONK_QUICK_ALLOW_NONROOT=1 HONK_QUICK_CONFIG="$config" HONK_QUICK_STATE_DIR="$state"
export HONK_QUICK_TOOL="$tool" HONK_QUICK_INIT="$init" HONK_QUICK_INIT_LOG="$tmp/init.log" HONK_QUICK_INIT_FAIL_ONCE_FILE="$tmp/fail-once"

candidate="$tmp/candidate"
printf 'candidate-config-bytes\n' >"$candidate"
chmod 600 "$candidate"
expected=$(sha256sum "$config" | cut -d ' ' -f1)
output=$(HONK_QUICK_PREVIOUS_RUNNING=false HONK_QUICK_PROBE=1 "$repo_root/honk/files/quick-transaction-worker" --apply "$candidate" "$expected" nonce-happy)
printf '%s\n' "$output" >"$evidence/apply.json"
jq -e '.ok == true and .stage == "committed" and .nonce == "nonce-happy"' "$evidence/apply.json" >/dev/null || fail "happy transaction result"
[ "$(cat "$config")" = 'candidate-config-bytes' ] || fail "candidate did not become config"
[ ! -e "$state/quick-transaction.previous" ] || fail "sidecar remained after commit"
grep -Fx 'start' "$HONK_QUICK_INIT_LOG" >/dev/null || fail "stopped candidate was not provisionally started"
jq -e '.stage == "committed" and (.stageHistory | index("prepared")) != null and (.stageHistory | index("candidate-written")) != null and (.stageHistory | index("service-transition")) != null and (.stageHistory | index("waiting-subscription")) != null and (.stageHistory | index("probing")) != null' "$state/quick-transaction.json" >/dev/null || fail "transaction stage history"
if grep -F 'candidate-config-bytes' "$state/quick-transaction.json" >/dev/null; then fail "raw candidate leaked into journal"; fi
pass "happy atomic transaction and stage history"

printf 'previous-again\n' >"$config"
chmod 600 "$config"
expected=$(sha256sum "$config" | cut -d ' ' -f1)
printf 'candidate-failure\n' >"$candidate"
rm -f "$HONK_QUICK_INIT_FAIL_ONCE_FILE"
set +e
HONK_QUICK_PREVIOUS_RUNNING=true "$repo_root/honk/files/quick-transaction-worker" --apply "$candidate" "$expected" nonce-failure >"$evidence/failure.json"
failure_code=$?
set -e
[ "$failure_code" -ne 0 ] || fail "restart failure unexpectedly committed"
jq -e '.ok == false and .error.code == "ROLLBACK"' "$evidence/failure.json" >/dev/null || fail "rollback error contract"
[ "$(cat "$config")" = 'previous-again' ] || fail "previous config was not restored"
jq -e '.stage == "restored"' "$state/quick-transaction.json" >/dev/null || fail "restored journal stage"
printf '%s\n' '{"fixture":"restart-failure","ok":false,"code":"ROLLBACK","configRestored":true}' >"$evidence/failures/restart-failure.json"
pass "restart failure restores previous bytes"

# If the recovery restart also fails, retain a degraded journal instead of
# claiming that the service state was restored.
printf 'degraded-previous\n' >"$config"
chmod 600 "$config"
expected=$(sha256sum "$config" | cut -d ' ' -f1)
printf 'degraded-candidate\n' >"$candidate"
export HONK_QUICK_INIT_FAIL=1
set +e
HONK_QUICK_PREVIOUS_RUNNING=true "$repo_root/honk/files/quick-transaction-worker" --apply "$candidate" "$expected" nonce-degraded >"$evidence/degraded.json"
degraded_code=$?
set -e
unset HONK_QUICK_INIT_FAIL
[ "$degraded_code" -ne 0 ] || fail "degraded recovery unexpectedly committed"
jq -e '.ok == false and .error.code == "ROLLBACK"' "$evidence/degraded.json" >/dev/null || fail "degraded error contract"
jq -e '.stage == "degraded"' "$state/quick-transaction.json" >/dev/null || fail "degraded journal stage"
printf '%s\n' '{"fixture":"recovery-failure","ok":false,"code":"ROLLBACK","stage":"degraded"}' >"$evidence/failures/recovery-failure.json"
pass "failed recovery is explicitly degraded"

# Recovery consumes an interrupted journal and never interprets raw bytes from
# the controller. The sidecar is the only source of previous configuration.
printf 'recovery-previous\n' >"$state/quick-transaction.previous"
chmod 600 "$state/quick-transaction.previous"
printf 'interrupted-candidate\n' >"$config"
chmod 600 "$config"
previous_sha=$(sha256sum "$state/quick-transaction.previous" | cut -d ' ' -f1)
cat >"$state/quick-transaction.json" <<EOF
{"schemaVersion":"honk.quick-transaction.v1","stage":"service-transition","previousSha256":"$previous_sha","stageHistory":["prepared","candidate-written","service-transition"],"previousRunning":false}
EOF
chmod 600 "$state/quick-transaction.json"
HONK_QUICK_INIT_FAIL=0 "$repo_root/honk/files/quick-transaction-worker" --recover >"$evidence/recovery.json"
jq -e '.recovered == true and .stage == "restored"' "$evidence/recovery.json" >/dev/null || fail "recovery result"
[ "$(cat "$config")" = 'recovery-previous' ] || fail "recovery did not restore sidecar"
[ ! -e "$state/quick-transaction.previous" ] || fail "recovery sidecar cleanup"
grep -Fx 'stop' "$HONK_QUICK_INIT_LOG" >/dev/null || fail "stopped state was not restored"
pass "journal recovery restores and cleans sidecar"

if rg -n 'M\.save\(entry\.candidate' "$repo_root/luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua" >/dev/null; then
	fail "controller fallback writes config directly"
fi
grep -F 'TRANSACTION_WORKER_UNAVAILABLE' "$repo_root/luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua" >/dev/null || fail "worker ownership error missing"
grep -F 'require_authenticated_session_acl_post_csrf' "$repo_root/luci-app-honk-legacy/luasrc/controller/honk_legacy.lua" >/dev/null || fail "authenticated ACL/CSRF guard missing"
pass "single writer and mutation guard contract"

jq -n --arg sha "$expected" \
	'{schemaVersion:"honk.quick-transaction.v1",ok:true,stages:["prepared","candidate-written","service-transition","waiting-subscription","probing","committed"],sidecarSha256:$sha,rawCandidateInJournal:false,assertions:14}' \
	>"$evidence/transaction-contract.json"
printf 'quick-transaction assertions=%s\n' "$assertions"
