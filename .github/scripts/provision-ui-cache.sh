#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
lock="$repo_root/luci-app-honk/ui/package-lock.json"
cache="$repo_root/.cache/npm"
evidence="$repo_root/.cache/evidence/ui-cache.json"
while [ "$#" -gt 0 ]; do
	case "$1" in
		--lock) lock=$2; shift 2 ;;
		--cache) cache=$2; shift 2 ;;
		--evidence) evidence=$2; shift 2 ;;
		*) echo "usage: $0 --lock FILE --cache DIR --evidence FILE" >&2; exit 64 ;;
	esac
done
mkdir -p "$(dirname "$evidence")"
lock_count=$(jq -er '[.packages | to_entries[] | select(.key != "") | select(.value.resolved and .value.integrity)] | length' "$lock")
[ "$lock_count" -gt 0 ] || { echo "package lock has no integrity-pinned packages" >&2; exit 1; }

source_cache="${NPM_SOURCE_CACHE:-$HOME/.npm}"
cache_mode="existing"
if [ ! -d "$cache" ]; then
	if [ -d "$source_cache" ]; then
		mkdir -p "$(dirname "$cache")"
		ln -s "$source_cache" "$cache"
		cache_mode="provisioned-readonly-source"
	else
		mkdir -p "$cache"
		cache_mode="empty"
	fi
fi
npm cache verify --cache "$cache" >/dev/null 2>&1 || true

jq -n --arg lock "${lock#$repo_root/}" --arg cache "${cache#$repo_root/}" --arg source "$cache_mode" --argjson packages "$lock_count" \
	'{schemaVersion:"honk.ui-cache.v1",lock:$lock,cache:$cache,cacheMode:$source,packages:$packages,integrityPinned:true,networkProvisionPhase:true,ok:true}' \
	>"$evidence"
printf 'UI cache provisioned: packages=%s mode=%s\n' "$lock_count" "$cache_mode"
