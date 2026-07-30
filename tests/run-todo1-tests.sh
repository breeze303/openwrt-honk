#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tests=(
	"$repo_root/tests/test-failing-first.sh"
	"$repo_root/tests/test-source-lock.sh"
	"$repo_root/tests/test-secret-provisioning.sh"
	"$repo_root/tests/test-scope.sh"
	"$repo_root/tests/test-lock-contracts.sh"
	"$repo_root/tests/adversarial-probes.sh"
)
count=0
for test_script in "${tests[@]}"; do
	bash "$test_script"
	count=$((count + 1))
done
printf 'todo1 focused test scripts=%s\n' "$count"
