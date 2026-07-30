#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
[ "$#" -ge 2 ] || { printf 'usage: %s workspace|ebpf CARGO_SUBCOMMAND [ARGS...]\n' "$0" >&2; exit 64; }
closure=$1
shift

case "$closure" in
	workspace)
		config="$repo_root/tooling/cargo-workspace-offline.toml"
		workdir="$repo_root/.cache/work/honk-63e271065246bb68ecadf9ae53abecf748806ad3"
		;;
	ebpf)
		config="$repo_root/tooling/cargo-ebpf-offline.toml"
		workdir="$repo_root/.cache/work/honk-63e271065246bb68ecadf9ae53abecf748806ad3/crates/honk-ebpf"
		;;
	*) printf 'unknown closure: %s\n' "$closure" >&2; exit 64 ;;
esac

cd "$workdir"
exec cargo --config "$config" "$@" --frozen --offline
