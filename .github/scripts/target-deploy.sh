#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
target=root@192.168.1.191
password_fd=
package=
luci_package=
evidence="$repo_root/.cache/evidence/target-deploy"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--target) target=$2; shift 2 ;;
		--password-fd) password_fd=$2; shift 2 ;;
		--package) package=$2; shift 2 ;;
		--luci-package) luci_package=$2; shift 2 ;;
		--evidence) evidence=$2; shift 2 ;;
		*) printf 'usage: %s --target USER@HOST --password-fd FD --package APK --luci-package APK --evidence DIR\n' "$0" >&2; exit 64 ;;
	esac
done
[ -f "$package" ] || { printf 'package not found\n' >&2; exit 64; }
[ -f "$luci_package" ] || { printf 'luci package not found\n' >&2; exit 64; }
[ -n "$password_fd" ] && [[ "$password_fd" =~ ^[0-9]+$ ]] || { printf 'password FD required\n' >&2; exit 64; }
case "$target" in
	*[!A-Za-z0-9_.@:-]*) printf 'target contains unsupported shell characters\n' >&2; exit 64 ;;
esac

mkdir -p "$evidence"
chmod 700 "$evidence"
umask 077
password=$(cat <&"$password_fd")
[ -n "$password" ] || { printf 'password FD was empty\n' >&2; exit 64; }
known_hosts=${HONK_TARGET_KNOWN_HOSTS:-/tmp/honk-target-known_hosts}
: >"$known_hosts"
chmod 600 "$known_hosts"
timeout_secs=${HONK_TARGET_TIMEOUT:-600}
ssh_opts=(-o BatchMode=no -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts" -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR)

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

nonce=$(printf '%s' "$$-$(date +%s%N 2>/dev/null || date +%s)" | sha256sum | cut -c1-16)
remote_root=/tmp/honk-fresh-$nonce
remote_apk=$remote_root.apk
remote_luci=$remote_root-luci.apk
remote_helper="$repo_root/.github/scripts/target-deploy-remote.sh"
apk_sha=$(sha256sum "$package" | cut -d ' ' -f 1)
luci_sha=$(sha256sum "$luci_package" | cut -d ' ' -f 1)
apk_size=$(stat -c '%s' "$package")
luci_size=$(stat -c '%s' "$luci_package")
jq -n --arg target "$target" --arg packageSha "$apk_sha" --arg luciSha "$luci_sha" --argjson packageSize "$apk_size" --argjson luciSize "$luci_size" \
	'{schemaVersion:"honk.target-deploy-input.v1",target:$target,package:{sha256:$packageSha,size:$packageSize},luciPackage:{sha256:$luciSha,size:$luciSize},passwordPersisted:false}' >"$evidence/input.json"

cleanup_remote() {
	set +e
	ssh_with_password "rm -rf '$remote_root' '$remote_apk' '$remote_luci'"
	set -e
}
trap cleanup_remote EXIT INT TERM

if ! copy_with_password "$package" "$remote_apk" || ! copy_with_password "$luci_package" "$remote_luci"; then
	jq -n '{schemaVersion:"honk.target-deploy.v1",ok:false,status:"blocked",reason:"TRANSFER_FAILED"}' >"$evidence/receipt.json"
	exit 2
fi
set +e
exec {script_fd}<<<"$password"
raw=$(timeout "$timeout_secs" sshpass -d "$script_fd" ssh "${ssh_opts[@]}" "$target" sh -s -- "$remote_apk" "$remote_luci" "$nonce" "$apk_sha" "$luci_sha" "$apk_size" "$luci_size" <"$remote_helper")
remote_rc=$?
eval "exec $script_fd<&-"
set -e
receipt=$(printf '%s\n' "$raw" | jq -c 'select(.schemaVersion == "honk.target-deploy.v1")' 2>/dev/null | tail -n1)
if [ -n "$receipt" ] && printf '%s\n' "$receipt" | jq -e . >/dev/null 2>&1; then
	printf '%s\n' "$receipt" >"$evidence/receipt.json"
else
	jq -n --argjson remoteRc "$remote_rc" '{schemaVersion:"honk.target-deploy.v1",ok:false,status:"blocked",reason:"REMOTE_NO_RECEIPT",remoteExit:$remoteRc}' >"$evidence/receipt.json"
	printf '%s\n' "$raw" | sed -E 's#(https?://[^/@:]+:)[^/@]+@#\1REDACTED@#g; s#(token|secret|password|key)[^:]*:[[:space:]]*[^,} ]+#\1:REDACTED#gI' >"$evidence/remote-output.log"
fi
if [ "$remote_rc" -eq 0 ] && jq -e '.ok == true' "$evidence/receipt.json" >/dev/null 2>&1; then exit 0; fi
exit 2
