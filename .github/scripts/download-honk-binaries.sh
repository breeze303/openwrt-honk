#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
readonly package_arch=${PACKAGE_ARCH:?PACKAGE_ARCH is required}
readonly repository=${GITHUB_REPOSITORY:-breeze303/openwrt-honk}

case "$package_arch" in
	x86_64|aarch64) ;;
	*) printf 'unsupported package architecture: %s\n' "$package_arch" >&2; exit 1 ;;
esac

pkg_version=$(sed -n 's/^PKG_VERSION:=//p' "$repo_root/honk/Makefile" | head -n 1)
pkg_release=$(sed -n 's/^PKG_RELEASE:=//p' "$repo_root/honk/Makefile" | head -n 1)
source_revision=$(sed -n 's/^PKG_SOURCE_VERSION:=//p' "$repo_root/honk/source.mk" | head -n 1)
short_revision=${source_revision:0:7}
version=${HONK_BINARY_VERSION:-${pkg_version}-r${pkg_release}_${short_revision}}
release_tag=${HONK_BINARY_RELEASE_TAG:-honk_binaries_${version}}
archive="honk-${version}-${package_arch}.tar.gz"
base_url="https://github.com/${repository}/releases/download/${release_tag}"
stage_dir="$repo_root/honk/files/bin"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

for asset in "$archive" "$archive.sha256"; do
	curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
		--location --retry 5 --retry-all-errors --retry-delay 3 \
		--output "$tmp/$asset" "$base_url/$asset"
done

(
	cd "$tmp"
	sha256sum -c "$archive.sha256"
	mkdir unpacked
	tar -xzf "$archive" -C unpacked
	cd unpacked
	sha256sum -c SHA256SUMS
	jq -e \
		--arg version "$version" \
		--arg architecture "$package_arch" \
		'.version == $version and .architecture == $architecture and .libc == "musl" and .linkage == "static"' \
		manifest.json >/dev/null
)

rm -rf "$stage_dir"
mkdir -p "$stage_dir"
install -m 0755 "$tmp/unpacked/honk-core" "$stage_dir/honk-core"
install -m 0755 "$tmp/unpacked/honk-tool" "$stage_dir/honk-tool"
install -m 0644 "$tmp/unpacked/manifest.json" "$stage_dir/manifest.json"
install -m 0644 "$tmp/unpacked/SHA256SUMS" "$stage_dir/SHA256SUMS"
printf 'staged Honk %s binaries for %s\n' "$version" "$package_arch"
