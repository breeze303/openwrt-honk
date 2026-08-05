#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
target=root@192.168.1.191
password_fd=
evidence="$repo_root/.cache/evidence/target-fixture-probe"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--target) target=$2; shift 2 ;;
		--password-fd) password_fd=$2; shift 2 ;;
		--evidence) evidence=$2; shift 2 ;;
		*) printf 'usage: %s --target USER@HOST --password-fd FD --evidence DIR\n' "$0" >&2; exit 64 ;;
	esac
done
[ -n "$password_fd" ] && [[ "$password_fd" =~ ^[0-9]+$ ]] || { printf 'password FD required\n' >&2; exit 64; }
mkdir -p "$evidence"
chmod 700 "$evidence"
umask 077
password=$(cat <&"$password_fd")
[ -n "$password" ] || { printf 'password FD empty\n' >&2; exit 64; }
known_hosts=${HONK_TARGET_KNOWN_HOSTS:-/tmp/honk-target-known_hosts}
: >"$known_hosts"
chmod 600 "$known_hosts"
timeout_secs=${HONK_TARGET_TIMEOUT:-180}
ssh_opts=(-o BatchMode=no -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts" -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR)
nonce=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)" | sha256sum | cut -c1-8)
helper="$repo_root/.github/scripts/target-fixture-probe-remote.sh"
set +e
exec {fd}<<<"$password"
raw=$(timeout "$timeout_secs" sshpass -d "$fd" ssh "${ssh_opts[@]}" "$target" sh -s -- "$nonce" <"$helper")
remote_rc=$?
eval "exec $fd<&-"
set -e
receipt=$(printf '%s\n' "$raw" | jq -c 'select(.schemaVersion == "honk.target-fixture.v1")' 2>/dev/null | tail -n1)
if [ -n "$receipt" ] && printf '%s\n' "$receipt" | jq -e . >/dev/null 2>&1; then
	printf '%s\n' "$receipt" >"$evidence/receipt.json"
else
	jq -n --argjson remoteRc "$remote_rc" '{schemaVersion:"honk.target-fixture.v1",status:"blocked",ok:false,reason:"REMOTE_FIXTURE_NO_RECEIPT",remoteExit:$remoteRc}' >"$evidence/receipt.json"
	printf '%s\n' "$raw" >"$evidence/remote-output.log"
fi
cat "$evidence/receipt.json"
exit 2
