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
	"$repo_root/tests/test-subscription-node-groups.sh"
	"$repo_root/tests/test-geo-contract.sh"
	"$repo_root/tests/test-network-discovery.sh"
	"$repo_root/tests/test-quick-setup-contract.sh"
	"$repo_root/tests/test-dns-projection.sh"
	"$repo_root/tests/test-quick-transaction.sh"
	"$repo_root/tests/test-luci-package-isolation.sh"
	"$repo_root/tests/test-luci-v2-contract.sh"
	"$repo_root/tests/test-target-harness-contract.sh"
)
count=0
for test_script in "${tests[@]}"; do
	bash "$test_script"
	count=$((count + 1))
done
printf 'todo1 focused test scripts=%s\n' "$count"
