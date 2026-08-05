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
	rm -rf /usr/lib/honk /usr/share/honk /usr/bin/honk-tool
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

inode_of() {
	ls -di "$1" 2>/dev/null | awk 'NR == 1 {print $1}'
}

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
v2ray_exists=false
v2ray_hash_before=
v2ray_inode_before=
if [ -f /usr/share/v2ray/geosite.dat ]; then
	v2ray_exists=true
	v2ray_hash_before=$(sha256sum /usr/share/v2ray/geosite.dat | cut -d ' ' -f 1)
	v2ray_inode_before=$(inode_of /usr/share/v2ray/geosite.dat || printf '')
fi

save_path /usr/lib/honk
save_path /usr/share/honk
save_path /usr/bin/honk-tool
mkdir -p /usr/lib /usr/share /usr/bin
cp -a "$stage/usr/lib/honk" /usr/lib/honk
cp -a "$stage/usr/share/honk" /usr/share/honk
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

geo_locked_out=$stage/geo-locked.json
run_capture "$geo_locked_out" env DAE_LOCATION_ASSET=/usr/share/honk /usr/bin/honk-tool geo capabilities --json --labels gfw,cn,private --geoip-labels cn
geo_locked_rc=$(cat "$geo_locked_out.rc")
geo_locked=$(json_or_empty "$geo_locked_out")

rm -f /usr/share/honk/geosite.dat
if [ "$v2ray_exists" = true ]; then
	ln -s /usr/share/v2ray/geosite.dat /usr/share/honk/geosite.dat
fi
geo_v2fly_out=$stage/geo-v2fly.json
run_capture "$geo_v2fly_out" env DAE_LOCATION_ASSET=/usr/share/honk /usr/bin/honk-tool geo capabilities --json --labels gfw,cn,private --geoip-labels cn
geo_v2fly_rc=$(cat "$geo_v2fly_out.rc")
geo_v2fly=$(json_or_empty "$geo_v2fly_out")

repair_out=$stage/repair.json
run_capture "$repair_out" /usr/bin/honk-tool geo repair --json --confirm
repair_rc=$(cat "$repair_out.rc")
repair=$(json_or_empty "$repair_out")

geo_repaired_out=$stage/geo-repaired.json
run_capture "$geo_repaired_out" env DAE_LOCATION_ASSET=/usr/share/honk /usr/bin/honk-tool geo capabilities --json --labels gfw,cn,private --geoip-labels cn
geo_repaired_rc=$(cat "$geo_repaired_out.rc")
geo_repaired=$(json_or_empty "$geo_repaired_out")

validate_out=$stage/validate.json
run_capture "$validate_out" /usr/bin/honk-tool validate --config "$fixture_path" --json
validate_rc=$(cat "$validate_out.rc")
validate=$(json_or_empty "$validate_out")

v2ray_hash_after=
v2ray_inode_after=
if [ -f /usr/share/v2ray/geosite.dat ]; then
	v2ray_hash_after=$(sha256sum /usr/share/v2ray/geosite.dat | cut -d ' ' -f 1)
	v2ray_inode_after=$(inode_of /usr/share/v2ray/geosite.dat || printf '')
fi

restore_paths
config_after=
if [ -f /etc/honk/config.dae ]; then config_after=$(sha256sum /etc/honk/config.dae | cut -d ' ' -f 1); fi
tool_after_sha=
if [ -e /usr/bin/honk-tool ] || [ -L /usr/bin/honk-tool ]; then tool_after_sha=$(sha256sum /usr/bin/honk-tool | cut -d ' ' -f 1); fi
honk_paths_absent=true
if [ -e /usr/lib/honk ] || [ -L /usr/lib/honk ] || [ -e /usr/share/honk ] || [ -L /usr/share/honk ]; then honk_paths_absent=false; fi
installed_after=false
if apk info -e honk >/dev/null 2>&1; then installed_after=true; fi
service_after_rc=0
if /etc/init.d/honk status >/dev/null 2>&1; then service_after_rc=0; else service_after_rc=$?; fi

geo_locked_summary=$(printf '%s' "$geo_locked" | jq -c '{ok,diskStatus,activeStatus,providers,labels,geoipLabels,resolvedPaths,hashes,sizes,lockVersion}' 2>/dev/null || printf '{}')
geo_v2fly_summary=$(printf '%s' "$geo_v2fly" | jq -c '{ok,diskStatus,activeStatus,providers,resolvedPaths,hashes}' 2>/dev/null || printf '{}')
repair_summary=$(printf '%s' "$repair" | jq -c '{ok,repaired,path,resolvedPath,diskStatus,activeStatus,needsRestart}' 2>/dev/null || printf '{}')
geo_repaired_summary=$(printf '%s' "$geo_repaired" | jq -c '{ok,diskStatus,activeStatus,providers,labels,geoipLabels,resolvedPaths,hashes}' 2>/dev/null || printf '{}')
validate_summary=$(printf '%s' "$validate" | jq -c '{ok,configSha256,parserVersion,geo,diagnostics}' 2>/dev/null || printf '{}')

locked_ok=false
if [ "$geo_locked_rc" = 0 ] && printf '%s' "$geo_locked" | jq -e '(.ok == true and .diskStatus == "LOYALSOLDIER_LOCKED" and .activeStatus == "STALE" and ([.labels[]? | select(.present != true)] | length == 0) and ([.geoipLabels[]? | select(.present != true)] | length == 0))' >/dev/null 2>&1; then locked_ok=true; fi
v2fly_ok=false
if [ "$v2ray_exists" = true ] && [ "$geo_v2fly_rc" -ne 0 ] && printf '%s' "$geo_v2fly" | jq -e '.diskStatus == "V2FLY_GFW_UNSUPPORTED"' >/dev/null 2>&1; then v2fly_ok=true; fi
repair_ok=false
if [ "$repair_rc" = 0 ] && printf '%s' "$repair" | jq -e '.ok == true and .needsRestart == true and .resolvedPath == "/usr/lib/honk/geosite.dat"' >/dev/null 2>&1; then repair_ok=true; fi
repaired_ok=false
if [ "$geo_repaired_rc" = 0 ] && printf '%s' "$geo_repaired" | jq -e '.ok == true and .diskStatus == "LOYALSOLDIER_LOCKED" and .activeStatus == "STALE"' >/dev/null 2>&1; then repaired_ok=true; fi
validate_ok=false
if [ "$validate_rc" = 0 ] && printf '%s' "$validate" | jq -e --arg expected "$expected_fixture_sha" '.ok == true and .schemaVersion == "honk.validate.v1" and .configSha256 == $expected' >/dev/null 2>&1; then validate_ok=true; fi
transfer_ok=false
if [ "$transferred_apk_sha" = "$expected_apk_sha" ]; then transfer_ok=true; fi
restore_ok=false
if [ "$config_before" = "$config_after" ] && [ "$old_tool_sha" = "$tool_after_sha" ] && [ "$installed" = "$installed_after" ] && [ "$v2ray_hash_before" = "$v2ray_hash_after" ] && [ "$v2ray_inode_before" = "$v2ray_inode_after" ] && [ "$honk_paths_absent" = true ]; then restore_ok=true; fi
smoke_ok=false
if [ "$arch" = x86_64 ] && [ "$transfer_ok" = true ] && [ "$locked_ok" = true ] && [ "$v2fly_ok" = true ] && [ "$repair_ok" = true ] && [ "$repaired_ok" = true ] && [ "$validate_ok" = true ] && [ "$restore_ok" = true ]; then smoke_ok=true; fi

printf 'HONK_TARGET_RECEIPT_BEGIN\n'
jq -n \
	--arg arch "$arch" --arg release "$release" \
	--argjson installed "$installed" --argjson installedAfter "$installed_after" \
	--arg configBefore "$config_before" --arg configAfter "$config_after" \
	--arg oldToolSha "$old_tool_sha" --arg toolAfterSha "$tool_after_sha" \
	--argjson honkPathsAbsent "$honk_paths_absent" \
	--arg transferredApkSha "$transferred_apk_sha" --argjson transferOk "$transfer_ok" \
	--argjson serviceBeforeRc "$service_before_rc" --argjson serviceAfterRc "$service_after_rc" \
	--arg expectedApkSha "$expected_apk_sha" --argjson expectedApkSize "$expected_apk_size" \
	--arg expectedFixtureSha "$expected_fixture_sha" \
	--argjson geoLockedRc "$geo_locked_rc" --argjson geoV2flyRc "$geo_v2fly_rc" --argjson repairRc "$repair_rc" --argjson geoRepairedRc "$geo_repaired_rc" --argjson validateRc "$validate_rc" \
	--argjson lockedOk "$locked_ok" --argjson v2flyOk "$v2fly_ok" --argjson repairOk "$repair_ok" --argjson repairedOk "$repaired_ok" --argjson validateOk "$validate_ok" --argjson restoreOk "$restore_ok" \
	--argjson geoLocked "$geo_locked_summary" --argjson geoV2fly "$geo_v2fly_summary" --argjson repair "$repair_summary" --argjson geoRepaired "$geo_repaired_summary" --argjson validate "$validate_summary" \
	--arg v2Before "$v2ray_hash_before" --arg v2After "$v2ray_hash_after" --arg v2InodeBefore "$v2ray_inode_before" --arg v2AfterInode "$v2ray_inode_after" --argjson v2Exists "$v2ray_exists" --argjson smokeOk "$smoke_ok" \
	'{schemaVersion:"honk.target-package-smoke.v1",status:(if $smokeOk then "pass" else "partial" end),ok:$smokeOk,target:{arch:$arch,release:$release},package:{sha256:$expectedApkSha,transferredSha256:$transferredApkSha,transferVerified:$transferOk,size:$expectedApkSize,staged:true,packageDatabaseChanged:false},fixture:{configSha256:$expectedFixtureSha,configHashVerified:$validateOk,networkFixture:"not-installed",publicEgressGuard:"not-proven"},preexisting:{honkInstalled:$installed,honkInstalledAfter:$installedAfter,configSha256Before:$configBefore,configSha256After:$configAfter,serviceStatusRcBefore:$serviceBeforeRc,serviceStatusRcAfter:$serviceAfterRc},geo:{locked:$geoLocked,lockedRc:$geoLockedRc,v2flyDetection:$geoV2fly,v2flyRc:$geoV2flyRc,repair:$repair,repairRc:$repairRc,repaired:$geoRepaired,repairedRc:$geoRepairedRc},validate:$validate,checks:{transfer:$transferOk,locked:$lockedOk,v2flyDetection:$v2flyOk,repair:$repairOk,repaired:$repairedOk,validate:$validateOk,restore:$restoreOk,honkPathsAbsent:$honkPathsAbsent},neverTouch:{path:"/usr/share/v2ray/geosite.dat",exists:$v2Exists,sha256Before:$v2Before,sha256After:$v2After,inodeBefore:$v2InodeBefore,inodeAfter:$v2AfterInode},activeReceipt:"STALE_EXPECTED_DAEMON_NOT_STARTED",fullDataPlane:"blocked"}'
printf 'HONK_TARGET_RECEIPT_END\n'
