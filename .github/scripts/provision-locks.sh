#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
lock_dir="$repo_root/locks"
dl_dir="$repo_root/.cache/dl"
offline=false
check=false
stage_dir=''

while [ "$#" -gt 0 ]; do
	case "$1" in
		--lock-dir) lock_dir=$2; shift 2 ;;
		--dl-dir) dl_dir=$2; shift 2 ;;
		--offline) offline=true; shift ;;
		--check) check=true; shift ;;
		--stage-dir) stage_dir=$2; shift 2 ;;
		*) printf 'usage: %s --lock-dir DIR --dl-dir DIR [--offline] [--check]\n' "$0" >&2; exit 64 ;;
	esac
done

required='source toolchains openwrt-targets runtime-deps geo browser qemu test-helpers'
blocked=''
for name in $required; do
	lock="$lock_dir/$name.lock.json"
	if [ "$name" = source ]; then
		jq -e '
			.schemaVersion == 1 and
			(.source.canonicalUrl | type == "string" and startswith("https://")) and
			(.source.commit | test("^[0-9a-f]{40}$")) and
			(.source.tree | test("^[0-9a-f]{40}$")) and
			(.source.archive.sha256 | test("^[0-9a-f]{64}$")) and
			(.source.license.spdx | type == "string" and length > 0) and
			(.source.license.sourceLicenseUrl | startswith("https://")) and
			(.source.provenance.providerPath | type == "string" and length > 0) and
			(.source.archive.offlinePath | type == "string" and length > 0)
		' "$lock" >/dev/null || { printf 'invalid lock schema: %s\n' "$name" >&2; exit 1; }
	elif [ "$name" = geo ]; then
		jq -e '
			.schemaVersion == 2 and
			.contract.availability == "available" and
			.contract.activeDirectory == "/usr/share/honk" and
			.contract.runtimeDependency == false and
			([.contract.neverTouch[]] | index("/usr/share/v2ray/geosite.dat")) != null and
			([.assets[] | select(.kind == "geosite" and .provider == "LOYALSOLDIER" and .release == "202607312254" and .sha256 == "1f3a743e8e30152a870a1674792af3976361436dcb1f510a43c499d430f6b13f" and .labels == ["gfw", "cn", "private"])] | length == 1) and
			([.assets[] | select(.kind == "geoip" and .provider == "V2FLY" and .release == "202607171233" and .sha256 == "b71d1999439dde2de2d2b6844a2befa50c50211ff739785c005ca7c230a17d6a" and (.architectures | sort == ["aarch64", "x86_64"]))] | length == 1)
		' "$lock" >/dev/null || { printf 'invalid geo asset lock\n' >&2; exit 1; }
	else
		jq -e '
			.schemaVersion == 1 and
			(.contract.canonicalSourceUrl | type == "string" and length > 0) and
			(.contract.immutableVersion | type == "string" and length > 0) and
			(.contract.spdxLicense | type == "string" and length > 0) and
			(.contract.sourceLicenseUrl | type == "string" and startswith("https://")) and
			(.contract.providerPath | type == "string" and length > 0) and
			(.contract.offlineArchivePath | type == "string" and length > 0) and
			(.contract.availability | type == "string" and length > 0)
		' "$lock" >/dev/null || { printf 'invalid lock schema: %s\n' "$name" >&2; exit 1; }
	fi
	if [ "$name" = openwrt-targets ]; then
		jq -e '
			([.targets[] | select(.target == "x86" and .subtarget == "64" and .packageArch == "x86_64")] | length == 1) and
			([.targets[] | select(.target == "armsr" and .subtarget == "armv8" and .packageArch == "aarch64_generic")] | length == 1) and
			([.targets[] | select((.target | test("mips"; "i")) or (.packageArch | test("mips"; "i")))] | length == 0)
		' "$lock" >/dev/null || { printf 'target lock has an unsupported or mismatched architecture\n' >&2; exit 1; }
	fi
	if [ "$name" = qemu ] && [ "$(jq -er '.contract.availability' "$lock")" = available ]; then
		jq -e '.command | type == "string" and length > 0' "$lock" >/dev/null || { printf 'available QEMU lock has no command\n' >&2; exit 1; }
	fi
	canonical=$(mktemp)
	trap 'rm -f "$canonical"' EXIT INT TERM
	jq -S . "$lock" >"$canonical"
	cmp -s "$canonical" "$lock" || { printf 'lock is not canonical JSON: %s\n' "$name" >&2; exit 1; }
	rm -f "$canonical"
	trap - EXIT INT TERM
	if [ "$name" = source ]; then availability=available; else availability=$(jq -er '.contract.availability' "$lock"); fi
	if [ "$availability" != available ]; then
		blocked="$blocked $name"
	fi
done

geo_lock="$lock_dir/geo.lock.json"
while IFS=$'\t' read -r cache_path expected_sha expected_size; do
	[ -n "$cache_path" ] || continue
	asset="$dl_dir/$(basename "$cache_path")"
	if [ ! -f "$asset" ]; then
		asset="$repo_root/$cache_path"
	fi
	[ -f "$asset" ] || { printf 'locked geo asset is missing: %s\n' "$cache_path" >&2; exit 1; }
	[ "$(stat -c '%s' "$asset")" = "$expected_size" ] || { printf 'locked geo asset size mismatch: %s\n' "$cache_path" >&2; exit 1; }
	[ "$(sha256sum "$asset" | cut -d ' ' -f 1)" = "$expected_sha" ] || { printf 'locked geo asset hash mismatch: %s\n' "$cache_path" >&2; exit 1; }
	if [ -n "$stage_dir" ]; then
		mkdir -p "$stage_dir"
		cp "$asset" "$stage_dir/$(basename "$cache_path")"
		chmod 444 "$stage_dir/$(basename "$cache_path")"
	fi
done < <(jq -r '.assets[] | [.cachePath, .sha256, (.size|tostring)] | @tsv' "$geo_lock")

source_archive=$(jq -er '.source.archive.offlinePath' "$lock_dir/source.lock.json")
source_sha=$(jq -er '.source.archive.sha256' "$lock_dir/source.lock.json")
[ -f "$repo_root/$source_archive" ] || { printf 'locked source archive is missing\n' >&2; exit 1; }
[ "$(sha256sum "$repo_root/$source_archive" | cut -d ' ' -f 1)" = "$source_sha" ] || { printf 'locked source archive hash mismatch\n' >&2; exit 1; }

if "$check"; then
	printf 'lock manifests are canonical and source archive is present\n'
	exit 0
fi

if "$offline" && [ -n "$blocked" ]; then
	printf 'offline provisioning blocked by unavailable lock contracts:%s\n' "$blocked" >&2
	exit 1
fi

printf 'lock provisioning requires explicit online acquisition mode\n' >&2
exit 1
