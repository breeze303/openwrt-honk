#!/usr/bin/env bash
set -euo pipefail

mode=''
workspace=/home/breeze/honk-dev
out=''
baseline=''
require_honk_clean=false

while [ "$#" -gt 0 ]; do
	case "$1" in
		--capture) mode=capture; shift ;;
		--compare) mode=compare; shift ;;
		--workspace) workspace=$2; shift 2 ;;
		--out) out=$2; shift 2 ;;
		--baseline) baseline=$2; shift 2 ;;
		--require-honk-clean) require_honk_clean=true; shift ;;
		*) printf 'usage: %s --capture --out DIR | --compare --baseline DIR [--workspace DIR] [--require-honk-clean]\n' "$0" >&2; exit 64 ;;
	esac
done

capture() {
	local destination=$1
	local manifest="$destination/protected-manifest.ndjson0"
	mkdir -p "$destination"
	: >"$manifest"
	for checkout in honk luci-app-dae luci-app-homeproxy passwall; do
		local path
		path=$(realpath "$workspace/$checkout")
		printf '%s\n' "$path" >"$destination/$checkout.canonical-path"
		if GIT_MASTER=1 git -C "$path" rev-parse HEAD >"$destination/$checkout.head" 2>/dev/null; then
			GIT_MASTER=1 git -C "$path" status --porcelain=v2 -z >"$destination/$checkout.status.v2.nul"
		else
			printf 'not-a-git-checkout\n' >"$destination/$checkout.head"
			: >"$destination/$checkout.status.v2.nul"
		fi
		find "$path" -path "$path/.git" -prune -o -print0 | sort -z |
		while IFS= read -r -d '' entry; do
			local type target hash
			if [ -L "$entry" ]; then type=symlink; target=$(readlink "$entry"); hash=''
			elif [ -f "$entry" ]; then type=regular; target=''; hash=$(sha256sum <"$entry" | cut -d ' ' -f 1)
			elif [ -d "$entry" ]; then type=directory; target=''; hash=''
			else type=other; target=''; hash=''; fi
			jq -cn --arg checkout "$checkout" --arg path "${entry#"$workspace/"}" --arg type "$type" --arg mode "$(stat -c '%a' "$entry")" --arg uid "$(stat -c '%u' "$entry")" --arg gid "$(stat -c '%g' "$entry")" --arg target "$target" --arg sha256 "$hash" '{checkout:$checkout,path:$path,type:$type,mode:$mode,uid:$uid,gid:$gid,symlinkTarget:$target,sha256:$sha256}' | tr '\n' '\0' >>"$manifest"
		done
	done
	sha256sum "$manifest" | cut -d ' ' -f 1 >"$destination/protected-manifest.sha256"
}

capture_fast_aggregate() {
	local destination=$1
	: >"$destination/protected-tree.tar.sha256"
	for checkout in honk luci-app-dae luci-app-homeproxy passwall; do
		hash=$(tar --exclude=.git --numeric-owner --format=posix --sort=name --mtime='UTC 1970-01-01' -cf - -C "$workspace/$checkout" . | sha256sum | cut -d ' ' -f 1)
		printf '%s %s\n' "$checkout" "$hash" >>"$destination/protected-tree.tar.sha256"
	done
}

require_clean_honk() {
	[ "$(GIT_MASTER=1 git -C "$workspace/honk" rev-parse HEAD)" = 63e271065246bb68ecadf9ae53abecf748806ad3 ] || return 1
	[ -z "$(GIT_MASTER=1 git -C "$workspace/honk" status --porcelain=v2)" ] || return 1
	[ "$(GIT_MASTER=1 git -C "$workspace/honk" rev-parse 63e271065246bb68ecadf9ae53abecf748806ad3^{tree})" = 04e4d0e2a9e422130e228560526eb400e5e606c0 ] || return 1
}

case "$mode" in
	capture)
		[ -n "$out" ] || { printf 'capture requires --out\n' >&2; exit 64; }
		capture "$out"
		capture_fast_aggregate "$out"
		if "$require_honk_clean"; then require_clean_honk; fi
		printf 'scope captured\n'
		;;
	compare)
		[ -n "$baseline" ] || { printf 'compare requires --baseline\n' >&2; exit 64; }
		tmp=$(mktemp -d)
		cleanup() { rm -rf "$tmp"; }
		trap cleanup EXIT INT TERM
		capture "$tmp"
		cmp -s "$baseline/protected-manifest.ndjson0" "$tmp/protected-manifest.ndjson0"
		for checkout in honk luci-app-dae luci-app-homeproxy passwall; do
			cmp -s "$baseline/$checkout.canonical-path" "$tmp/$checkout.canonical-path"
			cmp -s "$baseline/$checkout.head" "$tmp/$checkout.head"
			cmp -s "$baseline/$checkout.status.v2.nul" "$tmp/$checkout.status.v2.nul"
		done
		if "$require_honk_clean"; then require_clean_honk; fi
		printf 'scope matches baseline\n'
		;;
	*) printf 'choose --capture or --compare\n' >&2; exit 64 ;;
esac
