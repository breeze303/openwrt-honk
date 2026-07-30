#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 1 ] || { printf 'usage: %s SOURCE_DIR\n' "$0" >&2; exit 64; }
source_dir=$1
cd "$source_dir"
exec unshare -Urn -- cargo fmt --all -- --check
