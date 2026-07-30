#!/usr/bin/env bash
set -euo pipefail
set +x

plan_fd=''
out_dir=''
json=false

while [ "$#" -gt 0 ]; do
	case "$1" in
		--plan-fd) plan_fd=$2; shift 2 ;;
		--out-dir) out_dir=$2; shift 2 ;;
		--json) json=true; shift ;;
		*) printf 'usage: %s --plan-fd FD --out-dir DIR [--json]\n' "$0" >&2; exit 64 ;;
	esac
done

fail() {
	printf 'secret provisioning failed: %s\n' "$1" >&2
	exit 1
}

[[ "$plan_fd" =~ ^[0-9]+$ ]] || fail 'plan FD must be numeric'
[ -d "$out_dir" ] && [ ! -L "$out_dir" ] || fail 'output directory must be a directory'
[ "$(findmnt -n -T "$out_dir" -o FSTYPE)" = tmpfs ] || fail 'output directory must be on tmpfs'
[ "$(stat -c '%a' "$out_dir")" = 700 ] || fail 'output directory mode must be 0700'

secret_key=LAB_VM_PASSWORD
secret=''
matches=0
while IFS= read -r line <&"$plan_fd"; do
	if [[ "$line" =~ $secret_key=([^[:space:]\`]+) ]]; then
		secret=${BASH_REMATCH[1]}
		matches=$((matches + 1))
	fi
done
[ "$matches" -eq 1 ] && [ -n "$secret" ] || fail 'plan FD has no single well-formed password marker'

for name in ssh-secret luci-credentials known-hosts storage-state transaction-state; do
	[ ! -e "$out_dir/$name" ] || fail 'output directory contains stale provisioning state'
done

umask 077
printf '%s\n' "$secret" >"$out_dir/ssh-secret"
printf 'root:%s\n' "$secret" >"$out_dir/luci-credentials"
: >"$out_dir/known-hosts"
printf 'created\n' >"$out_dir/storage-state"
printf '{"state":"created"}\n' >"$out_dir/transaction-state"
chmod 600 "$out_dir/ssh-secret" "$out_dir/luci-credentials" "$out_dir/known-hosts" "$out_dir/storage-state" "$out_dir/transaction-state"

if "$json"; then
	jq -n --arg outDir "$out_dir" '{status:"provisioned",outDir:$outDir,files:["ssh-secret","luci-credentials","known-hosts","storage-state","transaction-state"]}'
else
	printf 'secret files provisioned\n'
fi
