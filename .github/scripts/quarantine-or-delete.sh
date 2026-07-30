#!/bin/sh
set -eu
set +x

secret_dir=''
evidence=''
allowlist=''

while [ "$#" -gt 0 ]; do
	case "$1" in
		--dir) secret_dir=$2; shift 2 ;;
		--evidence) evidence=$2; shift 2 ;;
		--allowlist-json) allowlist=$2; shift 2 ;;
		*) printf 'usage: %s --dir DIR --evidence DIR --allowlist-json FILE\n' "$0" >&2; exit 64 ;;
	esac
done

[ -d "$secret_dir" ] || { printf 'cleanup failed: secret directory is absent\n' >&2; exit 1; }
jq -e '.schemaVersion == 1 and (.forbiddenNeedles | type == "array")' "$allowlist" >/dev/null
mkdir -p "$evidence"

secret_key=LAB_VM_PASSWORD
needle="${secret_key}="
if rg -l --fixed-strings "$needle" "$evidence" >/dev/null 2>&1; then
	quarantine="$evidence/quarantine/secret-scan-failed-$(date -u +%Y%m%dT%H%M%SZ)"
	mkdir -p "$(dirname -- "$quarantine")"
	mv "$secret_dir" "$quarantine"
	jq -n --arg action quarantined --arg reason evidence_marker_detected '{action:$action,reason:$reason}' >"$evidence/cleanup-receipt.json"
	printf 'cleanup quarantined secret input\n' >&2
	exit 1
fi

rm -rf "$secret_dir"
jq -n --arg action deleted --arg scannedEvidence "$evidence" '{action:$action,scannedEvidence:$scannedEvidence}' >"$evidence/cleanup-receipt.json"
printf 'cleanup deleted secret input\n'
