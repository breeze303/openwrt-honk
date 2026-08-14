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
geo_dir="$tmp/v2ray"
mkdir -p "$state" "$geo_dir"
printf 'fixture geosite\n' >"$geo_dir/geosite.dat"
printf 'fixture geoip\n' >"$geo_dir/geoip.dat"
printf 'previous-config-bytes\n' >"$config"
chmod 600 "$config"
cat >"$tool" <<'SH'
#!/bin/sh
case "${1:-}" in
  validate) printf '{"ok":true}\n'; exit 0 ;;
  *) exit 64 ;;
esac
SH
cat >"$init" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >>"${HONK_QUICK_INIT_LOG:?}"
[ -z "${HONK_QUICK_INIT_ENV_LOG:-}" ] || printf '%s:%s\n' "$1" "${HONK_QUICK_SKIP_RECOVERY:-0}" >>"$HONK_QUICK_INIT_ENV_LOG"
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
export HONK_QUICK_TOOL="$tool" HONK_QUICK_INIT="$init" HONK_QUICK_GEO_DIR="$geo_dir" HONK_QUICK_INIT_LOG="$tmp/init.log" HONK_QUICK_INIT_FAIL_ONCE_FILE="$tmp/fail-once"
export HONK_QUICK_SKIP_HEALTHCHECK=1 HONK_QUICK_INIT_ENV_LOG="$tmp/init-env.log"

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
grep -Fx 'start:1' "$HONK_QUICK_INIT_ENV_LOG" >/dev/null || fail "worker did not suppress init recovery while holding its lock"
jq -e '.stage == "committed" and (.stageHistory | index("prepared")) != null and (.stageHistory | index("candidate-written")) != null and (.stageHistory | index("service-transition")) != null and (.stageHistory | index("waiting-subscription")) != null and (.stageHistory | index("probing")) != null' "$state/quick-transaction.json" >/dev/null || fail "transaction stage history"
if grep -F 'candidate-config-bytes' "$state/quick-transaction.json" >/dev/null; then fail "raw candidate leaked into journal"; fi
pass "happy atomic transaction and stage history"

# The init script may return success before procd creates an instance.  The
# worker must wait for honk-core rather than committing that partial start.
health_bin="$tmp/health-bin"
health_file="$tmp/honk-core-ready"
health_init="$tmp/health-init"
mkdir -p "$health_bin"
cat >"$health_bin/pidof" <<'SH'
#!/bin/sh
[ "${1:-}" = honk-core ] && [ -e "${HONK_QUICK_HEALTH_FILE:?}" ] && cat "${HONK_QUICK_HEALTH_FILE:?}" && exit 0
exit 1
SH
cat >"$health_init" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >>"${HONK_QUICK_INIT_LOG:?}"
[ -z "${HONK_QUICK_INIT_ENV_LOG:-}" ] || printf '%s:%s\n' "$1" "${HONK_QUICK_SKIP_RECOVERY:-0}" >>"$HONK_QUICK_INIT_ENV_LOG"
[ "$1" != start ] || printf 'new-core\n' >"${HONK_QUICK_HEALTH_FILE:?}"
exit 0
SH
chmod 700 "$health_bin/pidof" "$health_init"
printf 'health-previous\n' >"$config"
printf 'health-candidate\n' >"$candidate"
chmod 600 "$config" "$candidate"
expected=$(sha256sum "$config" | cut -d ' ' -f1)
rm -f "$health_file"
PATH="$health_bin:$PATH" HONK_QUICK_SKIP_HEALTHCHECK=0 HONK_QUICK_HEALTH_ATTEMPTS=1 \
	HONK_QUICK_HEALTH_FILE="$health_file" HONK_QUICK_INIT="$health_init" HONK_QUICK_PREVIOUS_RUNNING=false \
	"$repo_root/honk/files/quick-transaction-worker" --apply "$candidate" "$expected" nonce-health >"$evidence/health.json"
jq -e '.ok == true and .action == "start"' "$evidence/health.json" >/dev/null || fail "core health check transaction result"
grep -Fx 'start:1' "$HONK_QUICK_INIT_ENV_LOG" >/dev/null || fail "health transaction did not suppress nested recovery"
pass "transaction waits for a real core process"

# A process from the previous generation must not satisfy the candidate health
# check while procd is still stopping it.
stale_init="$tmp/stale-init"
cat >"$stale_init" <<'SH'
#!/bin/sh
printf '%s:%s\n' "$1" "${HONK_QUICK_SKIP_RECOVERY:-0}" >>"${HONK_QUICK_INIT_ENV_LOG:?}"
exit 0
SH
chmod 700 "$stale_init"
printf 'stale-previous\n' >"$config"
printf 'stale-candidate\n' >"$candidate"
chmod 600 "$config" "$candidate"
expected=$(sha256sum "$config" | cut -d ' ' -f1)
printf 'old-core\n' >"$health_file"
set +e
PATH="$health_bin:$PATH" HONK_QUICK_SKIP_HEALTHCHECK=0 HONK_QUICK_HEALTH_ATTEMPTS=1 \
	HONK_QUICK_HEALTH_FILE="$health_file" HONK_QUICK_INIT="$stale_init" HONK_QUICK_PREVIOUS_RUNNING=false \
	"$repo_root/honk/files/quick-transaction-worker" --apply "$candidate" "$expected" nonce-stale >"$evidence/stale.json"
stale_code=$?
set -e
[ "$stale_code" -ne 0 ] || fail "previous core process unexpectedly committed the candidate"
jq -e '.ok == false and .error.code == "ROLLBACK"' "$evidence/stale.json" >/dev/null || fail "stale core result"
[ "$(cat "$config")" = 'stale-previous' ] || fail "stale core did not restore previous config"
printf '%s\n' '{"fixture":"stale-core","ok":false,"code":"ROLLBACK","configRestored":true}' >"$evidence/failures/stale-core.json"
pass "previous core process does not satisfy health"

# A successful init command is not enough: retain the old configuration when
# procd never creates the core process after the requested start.
unhealthy_init="$tmp/unhealthy-init"
cat >"$unhealthy_init" <<'SH'
#!/bin/sh
printf '%s:%s\n' "$1" "${HONK_QUICK_SKIP_RECOVERY:-0}" >>"${HONK_QUICK_INIT_ENV_LOG:?}"
exit 0
SH
chmod 700 "$unhealthy_init"
printf 'unhealthy-previous\n' >"$config"
printf 'unhealthy-candidate\n' >"$candidate"
chmod 600 "$config" "$candidate"
expected=$(sha256sum "$config" | cut -d ' ' -f1)
rm -f "$health_file"
set +e
PATH="$health_bin:$PATH" HONK_QUICK_SKIP_HEALTHCHECK=0 HONK_QUICK_HEALTH_ATTEMPTS=1 \
	HONK_QUICK_HEALTH_FILE="$health_file" HONK_QUICK_INIT="$unhealthy_init" HONK_QUICK_PREVIOUS_RUNNING=false \
	"$repo_root/honk/files/quick-transaction-worker" --apply "$candidate" "$expected" nonce-unhealthy >"$evidence/unhealthy.json"
unhealthy_code=$?
set -e
[ "$unhealthy_code" -ne 0 ] || fail "service start without a core process unexpectedly committed"
jq -e '.ok == false and .error.code == "ROLLBACK"' "$evidence/unhealthy.json" >/dev/null || fail "unhealthy service result"
[ "$(cat "$config")" = 'unhealthy-previous' ] || fail "unhealthy service did not restore previous config"
grep -Fx 'start:1' "$HONK_QUICK_INIT_ENV_LOG" >/dev/null || fail "unhealthy service did not suppress nested recovery"
printf '%s\n' '{"fixture":"missing-core","ok":false,"code":"ROLLBACK","configRestored":true}' >"$evidence/failures/missing-core.json"
pass "missing core process rolls back the transaction"

# Preserve is used by source updates and runtime preparation. A stopped
# service must remain stopped while the validated configuration is committed.
printf 'preserve-previous\n' >"$config"
chmod 600 "$config"
printf 'preserve-candidate\n' >"$candidate"
chmod 600 "$candidate"
expected=$(sha256sum "$config" | cut -d ' ' -f1)
before_init_lines=$(wc -l <"$HONK_QUICK_INIT_LOG")
HONK_QUICK_PREVIOUS_RUNNING=false "$repo_root/honk/files/quick-transaction-worker" --apply "$candidate" "$expected" nonce-preserve preserve >"$evidence/preserve.json"
jq -e '.ok == true and .stage == "committed" and .action == "none"' "$evidence/preserve.json" >/dev/null || fail "preserve transaction result"
[ "$(cat "$config")" = 'preserve-candidate' ] || fail "preserve candidate did not become config"
[ "$(wc -l <"$HONK_QUICK_INIT_LOG")" -eq "$before_init_lines" ] || fail "preserve transaction started a stopped service"
pass "preserve transaction keeps a stopped service stopped"

# ImmortalWrt's BusyBox image has no stat applet.  Candidate validation must
# retain its exact 0600 check without relying on an optional coreutils tool.
printf 'no-stat-previous\n' >"$config"
chmod 600 "$config"
printf 'no-stat-candidate\n' >"$candidate"
chmod 600 "$candidate"
expected=$(sha256sum "$config" | cut -d ' ' -f1)
no_stat_bin="$tmp/no-stat-bin"
mkdir -p "$no_stat_bin"
cat >"$no_stat_bin/stat" <<'SH'
#!/bin/sh
exit 127
SH
chmod 700 "$no_stat_bin/stat"
PATH="$no_stat_bin:$PATH" HONK_QUICK_PREVIOUS_RUNNING=false "$repo_root/honk/files/quick-transaction-worker" --apply "$candidate" "$expected" nonce-no-stat preserve >"$evidence/no-stat.json"
jq -e '.ok == true and .stage == "committed" and .action == "none"' "$evidence/no-stat.json" >/dev/null || fail "candidate validation without stat"
[ "$(cat "$config")" = 'no-stat-candidate' ] || fail "no-stat candidate did not become config"
pass "candidate validation does not depend on stat"

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

grep -F "const WORKER = '/usr/libexec/honk/quick-transaction-worker';" "$repo_root/luci-app-honk/ucode/honk/service.uc" >/dev/null || fail "Ucode worker path missing"
grep -F 'write_candidate' "$repo_root/luci-app-honk/ucode/honk/config.uc" >/dev/null || fail "Ucode candidate staging missing"
if rg -n 'writefile\(config\.CONFIG|/etc/honk/config\.dae.*writefile' "$repo_root/luci-app-honk/ucode" >/dev/null; then
	fail "Ucode service bypasses transaction worker"
fi
pass "single writer and mutation guard contract"

jq -n --arg sha "$expected" \
	'{schemaVersion:"honk.quick-transaction.v1",ok:true,stages:["prepared","candidate-written","service-transition","waiting-subscription","probing","committed"],sidecarSha256:$sha,rawCandidateInJournal:false,preserveKeepsStopped:true,assertions:17}' \
	>"$evidence/transaction-contract.json"
printf 'quick-transaction assertions=%s\n' "$assertions"
