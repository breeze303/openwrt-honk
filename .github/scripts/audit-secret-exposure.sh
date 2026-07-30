#!/usr/bin/env bash
set -euo pipefail
set +x

evidence=''
scan_dir=''

while [ "$#" -gt 0 ]; do
	case "$1" in
		--evidence) evidence=$2; shift 2 ;;
		--scan-dir) scan_dir=$2; shift 2 ;;
		*) printf 'usage: %s --evidence DIR [--scan-dir DIR]\n' "$0" >&2; exit 64 ;;
	esac
done

mkdir -p "$evidence"
secret_key=LAB_VM_PASSWORD
needle="${secret_key}="
scanned=0
for pid_dir in /proc/[0-9]*; do
	for field in cmdline environ; do
		path="$pid_dir/$field"
		[ -r "$path" ] || continue
		scanned=$((scanned + 1))
		if grep -aqF "$needle" "$path" 2>/dev/null; then
			printf 'secret exposure audit failed\n' >&2
			exit 1
		fi
	done
done
if [ -n "$scan_dir" ] && rg -l --hidden --no-ignore --fixed-strings "$needle" "$scan_dir" >/dev/null 2>&1; then
	printf 'secret exposure audit failed\n' >&2
	exit 1
fi
jq -n --argjson procEntries "$scanned" '{status:"clear",procEntries:$procEntries}' >"$evidence/proc-secret-audit.json"
printf 'secret exposure audit passed\n'
