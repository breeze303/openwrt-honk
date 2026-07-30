#!/usr/bin/env bash
set -euo pipefail
set +x

known_hosts=''
password_fd=''
out=''
while [ "$#" -gt 0 ]; do
	case "$1" in
		--known-hosts) known_hosts=$2; shift 2 ;;
		--password-fd) password_fd=$2; shift 2 ;;
		--out) out=$2; shift 2 ;;
		*) printf 'usage: %s --known-hosts FILE --password-fd FD --out FILE\n' "$0" >&2; exit 64 ;;
	esac
done

[[ "$password_fd" =~ ^[0-9]+$ ]] || { printf 'password FD must be numeric\n' >&2; exit 64; }
[ -f "$known_hosts" ] && [ "$(stat -c '%a' "$known_hosts")" = 600 ] || { printf 'known-hosts must be mode 0600\n' >&2; exit 1; }
mkdir -p "$(dirname -- "$out")"
umask 077
timeout 25 sshpass -d "$password_fd" ssh \
	-o BatchMode=no \
	-o StrictHostKeyChecking=accept-new \
	-o UserKnownHostsFile="$known_hosts" \
	-o GlobalKnownHostsFile=/dev/null \
	-o LogLevel=ERROR \
	root@192.168.1.191 \
	'ubus call system board; printf "\\n--openwrt-release--\\n"; cat /etc/openwrt_release; printf "\\n--uname--\\n"; uname -m; printf "\\n--apk--\\n"; apk --version' >"$out"
[ -s "$out" ] || { printf 'target preflight produced no facts\n' >&2; exit 1; }
