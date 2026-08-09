#!/bin/sh
set -eu

apk_path=$1
fixture_path=$2
nonce=$3
expected_apk_sha=$4
expected_apk_size=$5
expected_fixture_sha=$6
stage=/tmp/honk-target-$nonce
backup=/tmp/honk-target-$nonce-backup
manifest=$backup/manifest
restored=0

save_path() {
	path=$1
	rel=${path#/}
	if [ -e "$path" ] || [ -L "$path" ]; then
		mkdir -p "$backup/$(dirname "$rel")"
		mv "$path" "$backup/$rel"
		printf '%s\n' "$rel" >>"$manifest"
	fi
}

restore_paths() {
	[ "$restored" -eq 0 ] || return 0
	rm -f /usr/bin/honk-tool
	if [ -f "$manifest" ]; then
		while IFS= read -r rel; do
			[ -n "$rel" ] || continue
			mkdir -p "/$(dirname "$rel")"
			mv "$backup/$rel" "/$rel"
		done <"$manifest"
	fi
	restored=1
}

cleanup() {
	set +e
	restore_paths
	rm -rf "$stage" "$backup" "$apk_path" "$fixture_path"
}
trap cleanup EXIT INT TERM

mkdir -p "$stage" "$backup"
: >"$manifest"
apk extract --allow-untrusted --no-chown --destination "$stage" "$apk_path" >"$stage/extract.log" 2>&1
transferred_apk_sha=$(sha256sum "$apk_path" | cut -d ' ' -f 1)

arch=$(uname -m 2>/dev/null || printf unknown)
release=$(grep '^DISTRIB_RELEASE=' /etc/openwrt_release | head -n1 | cut -d= -f2- | tr -d "'\"")
installed=false
if apk info -e honk >/dev/null 2>&1; then installed=true; fi
config_before=
if [ -f /etc/honk/config.dae ]; then config_before=$(sha256sum /etc/honk/config.dae | cut -d ' ' -f 1); fi
old_tool_sha=
if [ -e /usr/bin/honk-tool ] || [ -L /usr/bin/honk-tool ]; then old_tool_sha=$(sha256sum /usr/bin/honk-tool | cut -d ' ' -f 1); fi
service_before_rc=0
if /etc/init.d/honk status >/dev/null 2>&1; then service_before_rc=0; else service_before_rc=$?; fi

save_path /usr/bin/honk-tool
mkdir -p /usr/bin
cp "$stage/usr/bin/honk-tool" /usr/bin/honk-tool
chmod 0755 /usr/bin/honk-tool

run_capture() {
	out=$1
	shift
	set +e
	"$@" >"$out" 2>"$out.err"
	rc=$?
	set -e
	printf '%s\n' "$rc" >"$out.rc"
}

json_or_empty() {
	file=$1
	if jq -ce . "$file" >/dev/null 2>&1; then
		jq -c . "$file"
	else
		printf '{}'
	fi
}

validate_out=$stage/validate.json
run_capture "$validate_out" /usr/bin/honk-tool validate --config "$fixture_path" --json
validate_rc=$(cat "$validate_out.rc")
validate=$(json_or_empty "$validate_out")

restore_paths
config_after=
if [ -f /etc/honk/config.dae ]; then config_after=$(sha256sum /etc/honk/config.dae | cut -d ' ' -f 1); fi
tool_after_sha=
if [ -e /usr/bin/honk-tool ] || [ -L /usr/bin/honk-tool ]; then tool_after_sha=$(sha256sum /usr/bin/honk-tool | cut -d ' ' -f 1); fi
installed_after=false
if apk info -e honk >/dev/null 2>&1; then installed_after=true; fi
service_after_rc=0
if /etc/init.d/honk status >/dev/null 2>&1; then service_after_rc=0; else service_after_rc=$?; fi

private_geo_paths_absent=true
if [ -e "$stage/usr/lib/honk" ] || [ -L "$stage/usr/lib/honk" ] || [ -e "$stage/usr/share/honk" ] || [ -L "$stage/usr/share/honk" ]; then private_geo_paths_absent=false; fi
validate_summary=$(printf '%s' "$validate" | jq -c '{ok,configSha256,parserVersion,geo,diagnostics}' 2>/dev/null || printf '{}')

validate_ok=false
if [ "$validate_rc" = 0 ] && printf '%s' "$validate" | jq -e --arg expected "$expected_fixture_sha" '.ok == true and .schemaVersion == "honk.validate.v1" and .configSha256 == $expected' >/dev/null 2>&1; then validate_ok=true; fi
transfer_ok=false
if [ "$transferred_apk_sha" = "$expected_apk_sha" ]; then transfer_ok=true; fi
restore_ok=false
if [ "$config_before" = "$config_after" ] && [ "$old_tool_sha" = "$tool_after_sha" ] && [ "$installed" = "$installed_after" ]; then restore_ok=true; fi
smoke_ok=false
if [ "$arch" = x86_64 ] && [ "$transfer_ok" = true ] && [ "$private_geo_paths_absent" = true ] && [ "$validate_ok" = true ] && [ "$restore_ok" = true ]; then smoke_ok=true; fi

printf 'HONK_TARGET_RECEIPT_BEGIN\n'
jq -n \
	--arg arch "$arch" --arg release "$release" \
	--argjson installed "$installed" --argjson installedAfter "$installed_after" \
	--arg configBefore "$config_before" --arg configAfter "$config_after" \
	--arg oldToolSha "$old_tool_sha" --arg toolAfterSha "$tool_after_sha" \
	--arg transferredApkSha "$transferred_apk_sha" --argjson transferOk "$transfer_ok" \
	--argjson serviceBeforeRc "$service_before_rc" --argjson serviceAfterRc "$service_after_rc" \
	--arg expectedApkSha "$expected_apk_sha" --argjson expectedApkSize "$expected_apk_size" \
	--arg expectedFixtureSha "$expected_fixture_sha" --argjson validateRc "$validate_rc" \
	--argjson privateGeoPathsAbsent "$private_geo_paths_absent" --argjson validateOk "$validate_ok" --argjson restoreOk "$restore_ok" \
	--argjson validate "$validate_summary" --argjson smokeOk "$smoke_ok" \
	'{schemaVersion:"honk.target-package-smoke.v2",status:(if $smokeOk then "pass" else "partial" end),ok:$smokeOk,target:{arch:$arch,release:$release},package:{sha256:$expectedApkSha,transferredSha256:$transferredApkSha,transferVerified:$transferOk,size:$expectedApkSize,staged:true,packageDatabaseChanged:false},fixture:{configSha256:$expectedFixtureSha,configHashVerified:$validateOk,networkFixture:"not-installed",publicEgressGuard:"not-proven"},preexisting:{honkInstalled:$installed,honkInstalledAfter:$installedAfter,configSha256Before:$configBefore,configSha256After:$configAfter,serviceStatusRcBefore:$serviceBeforeRc,serviceStatusRcAfter:$serviceAfterRc},validate:$validate,checks:{transfer:$transferOk,privateGeoPathsAbsent:$privateGeoPathsAbsent,validate:$validateOk,restore:$restoreOk},geo:{directory:"/usr/share/v2ray",packages:["v2ray-geoip","v2ray-geosite"],packageOwnsData:true},fullDataPlane:"blocked"}'
printf 'HONK_TARGET_RECEIPT_END\n'
