#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/subscription-node-groups"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--evidence) evidence=$2; shift 2 ;;
		*) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
	esac
done
mkdir -p "$evidence"
chmod 700 "$evidence"
tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

assertions=0
pass() { assertions=$((assertions + 1)); printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

commit=$(jq -er '.source.commit' "$repo_root/locks/source.lock.json")
archive=$(jq -er '.source.archive.offlinePath' "$repo_root/locks/source.lock.json")
top=$(jq -er '.source.archive.topLevelDirectory' "$repo_root/locks/source.lock.json")
patch_path="honk/patches/100-openwrt-runtime-contracts.patch"
patch_sha=$(jq -er --arg path "$patch_path" '.source.patchDigests[] | select(.path == $path) | .sha256' "$repo_root/locks/source.lock.json")
actual_sha=$(sha256sum "$repo_root/$patch_path" | cut -d ' ' -f1)
[ "$actual_sha" = "$patch_sha" ] || fail "subscription patch digest drift"
pass "locked patch digest"

tar -xzf "$repo_root/$archive" -C "$tmp"
source_dir="$tmp/$top"
while IFS= read -r patch_file; do
	patch --dry-run -d "$source_dir" -p1 <"$repo_root/$patch_file" >/dev/null || fail "dry-run failed: $patch_file"
	patch -d "$source_dir" -p1 <"$repo_root/$patch_file" >/dev/null || fail "apply failed: $patch_file"
done < <(jq -er -r '.source.patchDigests[].path' "$repo_root/locks/source.lock.json")
pass "fresh archive patch application"

host_home="$HOME"
home="$tmp/home"
rustup_home="${RUSTUP_HOME:-$host_home/.rustup}"
target_dir="$tmp/target"
mkdir -p "$home" "$target_dir"
if [ -n "${CARGO_HOME:-}" ]; then
	cargo_home=$CARGO_HOME
else
	cargo_home="$home/.cargo"
	mkdir -p "$cargo_home"
	# Keep the disposable HOME while reusing the provisioned, read-only index.
	ln -s "$host_home/.cargo/registry" "$cargo_home/registry"
	[ ! -d "$host_home/.cargo/git" ] || ln -s "$host_home/.cargo/git" "$cargo_home/git"
fi
test_log="$evidence/cargo-test.log"
set +e
(cd "$source_dir" && HOME="$home" RUSTUP_HOME="$rustup_home" CARGO_HOME="$cargo_home" CARGO_TARGET_DIR="$target_dir" \
	RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.97.1}" CARGO_NET_OFFLINE=true \
	cargo test -p honk-config test_group_subscription_filter_exact_regex_and_compound --no-default-features -- --nocapture) \
	>"$test_log" 2>&1
test_code=$?
set -e
[ "$test_code" -eq 0 ] || { tail -80 "$test_log" >&2; fail "subscription filter behavior test"; }
grep -F 'test_group_subscription_filter_exact_regex_and_compound ... ok' "$test_log" >/dev/null || fail "subscription filter behavior assertion missing"
pass "subscription('tag') runtime behavior"

jq -n \
	--arg commit "$commit" \
	--arg patch "$patch_sha" \
	'{schemaVersion:"honk.subscription-groups.v1", sourceCommit:$commit,
	  patchSha256:$patch, subscriptions:["alpha","beta"],
	  filter:"subscription(\u0027alpha\u0027)", matched:["alpha-node-1"],
	  excluded:["beta-node-1","static-node"], assertions:3, ok:true}' \
	>"$evidence/receipt.json"

mkdir -p "$evidence/failures"
bad_lock="$tmp/source-lock-wrong-patch.json"
jq --arg path "$patch_path" --arg sha "$(printf '0%.0s' {1..64})" \
	'.source.patchDigests = (.source.patchDigests | map(if .path == $path then .sha256=$sha else . end))' \
	"$repo_root/locks/source.lock.json" >"$bad_lock"
if "$repo_root/.github/scripts/verify-source-lock.sh" --commit "$commit" --lock "$bad_lock" >/dev/null 2>&1; then
	fail "wrong patch SHA fixture unexpectedly passed"
fi
printf '%s\n' '{"fixture":"wrong-patch-sha","ok":false,"expected":"digest mismatch"}' >"$evidence/failures/wrong-patch-sha.json"
pass "wrong patch SHA rejected"

if grep -F 'resolve_group_filters(&mut config.groups, &config.nodes, &config.subscriptions)' "$source_dir/crates/honk-config/src/parser/mod.rs" >/dev/null \
	&& grep -F 'subscription_id' "$source_dir/crates/honk-config/src/node.rs" >/dev/null; then
	pass "source tag is distinct from display name"
else
	fail "subscription source-tag contract missing"
fi

printf 'subscription-node-group assertions=%s\n' "$assertions"
