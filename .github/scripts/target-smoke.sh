#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
target=root@192.168.1.191
password_fd=
package=
luci_package=
evidence="$repo_root/.cache/evidence/target-smoke"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--target) target=$2; shift 2 ;;
		--password-fd) password_fd=$2; shift 2 ;;
		--package) package=$2; shift 2 ;;
		--luci-package) luci_package=$2; shift 2 ;;
		--evidence) evidence=$2; shift 2 ;;
		*) printf 'usage: %s --target USER@HOST --password-fd FD --package APK [--luci-package APK] --evidence DIR\n' "$0" >&2; exit 64 ;;
	esac
done

[ -n "$package" ] || { printf '%s\n' 'target smoke requires --package' >&2; exit 64; }
[ -f "$package" ] || { printf 'package not found: %s\n' "$package" >&2; exit 64; }
[ -n "$password_fd" ] && [[ "$password_fd" =~ ^[0-9]+$ ]] || {
	printf '%s\n' 'target smoke requires a numeric password FD' >&2
	exit 64
}
case "$target" in
	*[!A-Za-z0-9_.@:-]*) printf '%s\n' 'target contains unsupported shell characters' >&2; exit 64 ;;
esac

mkdir -p "$evidence/failures"
chmod 700 "$evidence"
umask 077
password=$(cat <&"$password_fd")
[ -n "$password" ] || { printf '%s\n' 'password FD was empty' >&2; exit 64; }

known_hosts=${HONK_TARGET_KNOWN_HOSTS:-/tmp/honk-target-known_hosts}
: >"$known_hosts"
chmod 600 "$known_hosts"
timeout_secs=420
if [ -n "${HONK_TARGET_TIMEOUT:-}" ]; then timeout_secs=$HONK_TARGET_TIMEOUT; fi
ssh_opts=(-o BatchMode=no -o StrictHostKeyChecking=accept-new
	-o UserKnownHostsFile="$known_hosts" -o GlobalKnownHostsFile=/dev/null
	-o LogLevel=ERROR)

ssh_with_password() {
	local fd rc
	exec {fd}<<<"$password"
	set +e
	timeout "$timeout_secs" sshpass -d "$fd" ssh "${ssh_opts[@]}" "$target" "$@"
	rc=$?
	set -e
	eval "exec $fd<&-"
	return "$rc"
}

copy_with_password() {
	local source=$1 destination=$2 fd rc
	exec {fd}<<<"$password"
	set +e
	cat "$source" | timeout "$timeout_secs" sshpass -d "$fd" ssh "${ssh_opts[@]}" "$target" "umask 077; cat > '$destination'"
	rc=$?
	set -e
	eval "exec $fd<&-"
	return "$rc"
}

package_sha=$(sha256sum "$package" | cut -d ' ' -f 1)
package_size=$(stat -c '%s' "$package")
luci_sha=
luci_size=0
if [ -n "$luci_package" ] && [ -f "$luci_package" ]; then
	luci_sha=$(sha256sum "$luci_package" | cut -d ' ' -f 1)
	luci_size=$(stat -c '%s' "$luci_package")
fi
fixture="$repo_root/tests/fixtures/quick-config.dae"
fixture_sha=$(sha256sum "$fixture" | cut -d ' ' -f 1)
nonce=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)" | sha256sum | cut -c1-16)
remote_root=/tmp/honk-target-$nonce
remote_apk=$remote_root.apk
remote_fixture=$remote_root-config.dae
remote_helper="$repo_root/.github/scripts/target-smoke-remote.sh"
artifact_path=$(printf '%s' "$package" | sed 's/"/\\"/g')
cat >"$evidence/artifact.json" <<JSON
{"schemaVersion":"honk.target-artifact.v1","package":{"path":"$artifact_path","sha256":"$package_sha","size":$package_size},"luciPackage":{"present":$([ -n "$luci_sha" ] && printf true || printf false),"sha256":"$luci_sha","size":$luci_size},"fixture":{"sha256":"$fixture_sha"}}
JSON

cleanup_remote() {
	set +e
	ssh_with_password "rm -rf '$remote_root' '$remote_apk' '$remote_fixture' '$remote_root-backup'"
	set -e
}
trap cleanup_remote EXIT INT TERM

if ! copy_with_password "$package" "$remote_apk"; then
	jq -n '{schemaVersion:"honk.target-package-smoke.v1",ok:false,status:"blocked",reason:"TRANSFER_PACKAGE_FAILED"}' >"$evidence/package-smoke.json"
	exit 2
fi
if ! copy_with_password "$fixture" "$remote_fixture"; then
	jq -n '{schemaVersion:"honk.target-package-smoke.v1",ok:false,status:"blocked",reason:"TRANSFER_FIXTURE_FAILED"}' >"$evidence/package-smoke.json"
	exit 2
fi

set +e
exec {script_fd}<<<"$password"
raw=$(timeout "$timeout_secs" sshpass -d "$script_fd" ssh "${ssh_opts[@]}" "$target" sh -s -- "$remote_apk" "$remote_fixture" "$nonce" "$package_sha" "$package_size" "$fixture_sha" <"$remote_helper")
remote_rc=$?
eval "exec $script_fd<&-"
set -e
receipt=$(printf '%s\n' "$raw" | awk '/^HONK_TARGET_RECEIPT_BEGIN$/{capture=1;next}/^HONK_TARGET_RECEIPT_END$/{capture=0}capture')
if [ -n "$receipt" ] && printf '%s\n' "$receipt" | jq -e . >/dev/null 2>&1; then
	printf '%s\n' "$receipt" >"$evidence/package-smoke.json"
else
	jq -n --argjson remoteRc "$remote_rc" '{schemaVersion:"honk.target-package-smoke.v1",ok:false,status:"blocked",reason:"REMOTE_SMOKE_NO_RECEIPT",remoteExit:$remoteRc}' >"$evidence/package-smoke.json"
	printf '%s\n' "$raw" | sed -E 's#(https?://[^/@:]+:)[^/@]+@#\1REDACTED@#g; s#(token|secret|password|key)[^:]*:[[:space:]]*[^,} ]+#\1:REDACTED#gI' >"$evidence/remote-output.log"
fi

if [ "$remote_rc" -eq 0 ] && jq -e '.ok == true' "$evidence/package-smoke.json" >/dev/null 2>&1; then
	exit 0
fi
exit 2
