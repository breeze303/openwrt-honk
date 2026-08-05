#!/bin/sh
set -eu

apk_path=$1
luci_path=$2
nonce=$3
expected_apk_sha=$4
expected_luci_sha=$5
expected_apk_size=$6
expected_luci_size=$7
stage=/tmp/honk-fresh-$nonce
config=/etc/honk/config.dae
config_backup=$stage/config-before
config_present_before=false
service_running_before=false

rm -rf "$stage"
mkdir -p "$stage"

sha() { sha256sum "$1" | awk '{print $1}'; }
status_rc() {
	set +e
	"$@" >/dev/null 2>&1
	rc=$?
	set -e
	return "$rc"
}

cleanup() {
	set +e
	/etc/init.d/honk stop >/dev/null 2>&1 || true
	rm -f /run/honk/geo-live.json /run/honk/geo-assets.json
	if pidof honk-core >/dev/null 2>&1; then
		for pid in $(pidof honk-core); do kill "$pid" 2>/dev/null || true; done
		sleep 1
	fi
	rm -rf /etc/honk
	if [ "$config_present_before" = true ] && [ -d "$config_backup" ]; then
		cp -a "$config_backup" /etc/honk
	fi
	if [ "$service_running_before" = true ]; then
		/etc/init.d/honk start >/dev/null 2>&1 || true
	fi
	rm -rf "$stage" "$apk_path" "$luci_path"
}
trap cleanup EXIT INT TERM

arch=$(uname -m 2>/dev/null || printf unknown)
release=$(grep '^DISTRIB_RELEASE=' /etc/openwrt_release 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "'\"")
before_honk=false
before_luci=false
apk info -e honk >/dev/null 2>&1 && before_honk=true || true
apk info -e luci-app-honk >/dev/null 2>&1 && before_luci=true || true
if [ -f /lib/apk/db/installed ]; then cp -p /lib/apk/db/installed "$stage/apk-installed.before"; fi
if [ -f /etc/apk/world ]; then cp -p /etc/apk/world "$stage/apk-world.before"; fi
if [ -d /etc/honk ]; then
	config_present_before=true
	cp -a /etc/honk "$config_backup"
fi
if pidof honk-core >/dev/null 2>&1; then service_running_before=true; fi

transferred_apk_sha=$(sha "$apk_path")
transferred_luci_sha=$(sha "$luci_path")
transferred_apk_size=$(wc -c <"$apk_path" | tr -d '[:space:]')
transferred_luci_size=$(wc -c <"$luci_path" | tr -d '[:space:]')
transfer_ok=false
[ "$transferred_apk_sha" = "$expected_apk_sha" ] && [ "$transferred_luci_sha" = "$expected_luci_sha" ] && [ "$transferred_apk_size" = "$expected_apk_size" ] && [ "$transferred_luci_size" = "$expected_luci_size" ] && transfer_ok=true

set +e
/etc/init.d/honk stop >"$stage/stop-before.log" 2>&1
stop_before_rc=$?
apk del honk luci-app-honk >"$stage/apk-del.log" 2>&1
remove_rc=$?
set -e
rm -rf /etc/honk /var/lib/honk /run/honk /usr/lib/honk /usr/share/honk /usr/bin/honk-tool /usr/libexec/honk /sys/fs/bpf/honk

simulate_rc=125
set +e
apk add --simulate --no-network --allow-untrusted --force-overwrite --upgrade "$apk_path" "$luci_path" >"$stage/apk-simulate.log" 2>&1
simulate_rc=$?
set -e
install_rc=125
if [ "$simulate_rc" -eq 0 ] && [ "$transfer_ok" = true ]; then
	set +e
	apk add --no-network --allow-untrusted --force-overwrite --upgrade "$apk_path" "$luci_path" >"$stage/apk-install.log" 2>&1
	install_rc=$?
	set -e
fi
install_ok=false
[ "$install_rc" -eq 0 ] && apk info -e honk >/dev/null 2>&1 && apk info -e luci-app-honk >/dev/null 2>&1 && install_ok=true

candidate_sha=
validate_rc=125
validate_ok=false
active_rc=125
active_ok=false
active_status=STALE
diagnose_rc=125
diagnose_ok=false
if [ "$install_ok" = true ]; then
	mkdir -p /etc/honk
	cat >"$config" <<'EOF'
global {
	lan_interface: 'br-lan'
	wan_interface: 'br-lan'
	log_level: info
	dial_mode: domain
	auto_config_kernel_parameter: false
}

routing {
	fallback: direct
}

experimental {
	cache_file {
		enabled: false
	}
}
EOF
	chmod 600 "$config"
	candidate_sha=$(sha "$config")
	set +e
	/usr/bin/honk-tool validate --config "$config" --json >"$stage/validate.json" 2>&1
	validate_rc=$?
	set -e
	if [ "$validate_rc" -eq 0 ] && jq -e '.ok == true' "$stage/validate.json" >/dev/null 2>&1; then validate_ok=true; fi
	if [ "$validate_ok" = true ]; then
		rm -f /run/honk/geo-live.json /run/honk/geo-assets.json
		set +e
		/etc/init.d/honk start >"$stage/service-start.log" 2>&1
		active_rc=$?
		set -e
		if [ "$active_rc" -eq 0 ]; then
			for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
				if [ -s /run/honk/geo-live.json ] && pidof honk-core >/dev/null 2>&1; then break; fi
				sleep 1
			done
		fi
		if [ -s /run/honk/geo-live.json ]; then
			set +e
			DAE_LOCATION_ASSET=/usr/share/honk /usr/bin/honk-tool geo capabilities --json --labels gfw,cn,private --geoip-labels cn >"$stage/active-geo.json" 2>&1
			geo_rc=$?
			set -e
			active_status=$(jq -r '.activeStatus // "STALE"' "$stage/active-geo.json" 2>/dev/null || printf STALE)
			if [ "$geo_rc" -eq 0 ] && jq -e '.ok == true and .activeStatus == "LOYALSOLDIER_LOCKED"' "$stage/active-geo.json" >/dev/null 2>&1; then active_ok=true; fi
		fi
		set +e
		/usr/bin/honk-tool diagnose --api '' >"$stage/diagnose.log" 2>&1
		diagnose_rc=$?
		set -e
		if [ "$diagnose_rc" -eq 0 ] && grep -q 'diagnose: all checks passed' "$stage/diagnose.log"; then diagnose_ok=true; fi
	fi
fi

/etc/init.d/honk stop >/dev/null 2>&1 || true
rm -f /run/honk/geo-live.json /run/honk/geo-assets.json
if pidof honk-core >/dev/null 2>&1; then
	for pid in $(pidof honk-core); do kill "$pid" 2>/dev/null || true; done
	sleep 2
fi
service_after_running=false

package_version=$(apk info -a honk 2>/dev/null | sed -n '1,4p' | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')
package_db_changed=false
world_changed=false
if [ -f "$stage/apk-installed.before" ] && [ -f /lib/apk/db/installed ] && ! cmp -s "$stage/apk-installed.before" /lib/apk/db/installed; then package_db_changed=true; fi
if [ -f "$stage/apk-world.before" ] && [ -f /etc/apk/world ] && ! cmp -s "$stage/apk-world.before" /etc/apk/world; then world_changed=true; fi
receipt_ok=false
[ "$transfer_ok" = true ] && [ "$simulate_rc" -eq 0 ] && [ "$install_ok" = true ] && [ "$validate_ok" = true ] && receipt_ok=true

jq -n \
	--arg arch "$arch" --arg release "$release" \
	--argjson beforeHonk "$before_honk" --argjson beforeLuci "$before_luci" \
	--argjson transferOk "$transfer_ok" --arg expectedApkSha "$expected_apk_sha" --arg transferredApkSha "$transferred_apk_sha" --arg expectedLuciSha "$expected_luci_sha" --arg transferredLuciSha "$transferred_luci_sha" \
	--argjson expectedApkSize "$expected_apk_size" --argjson transferredApkSize "$transferred_apk_size" --argjson expectedLuciSize "$expected_luci_size" --argjson transferredLuciSize "$transferred_luci_size" \
	--argjson stopBeforeRc "$stop_before_rc" --argjson removeRc "$remove_rc" --argjson simulateRc "$simulate_rc" --argjson installRc "$install_rc" --argjson installOk "$install_ok" --arg packageVersion "$package_version" \
	--argjson validateRc "$validate_rc" --argjson validateOk "$validate_ok" --arg candidateSha "$candidate_sha" --argjson activeRc "$active_rc" --argjson activeOk "$active_ok" --arg activeStatus "$active_status" \
	--argjson diagnoseRc "$diagnose_rc" --argjson diagnoseOk "$diagnose_ok" --argjson serviceAfterRunning "$service_after_running" --argjson packageDbChanged "$package_db_changed" --argjson worldChanged "$world_changed" --argjson ok "$receipt_ok" \
	'{schemaVersion:"honk.target-deploy.v1",ok:$ok,status:(if $ok then "installed" else "partial" end),target:{arch:$arch,release:$release},freshInstall:true,previousPackages:{honk:$beforeHonk,luciAppHonk:$beforeLuci},transfer:{honk:{expectedSha256:$expectedApkSha,transferredSha256:$transferredApkSha,expectedSize:$expectedApkSize,transferredSize:$transferredApkSize},luci:{expectedSha256:$expectedLuciSha,transferredSha256:$transferredLuciSha,expectedSize:$expectedLuciSize,transferredSize:$transferredLuciSize},verified:$transferOk},install:{stopBeforeRc:$stopBeforeRc,removeRc:$removeRc,simulateRc:$simulateRc,installRc:$installRc,verified:$installOk,packageVersion:$packageVersion,packageDatabaseChanged:$packageDbChanged,worldChanged:$worldChanged},active:{configSha256:$candidateSha,validateRc:$validateRc,validateOk:$validateOk,startRc:$activeRc,ok:$activeOk,provider:$activeStatus,diagnoseRc:$diagnoseRc,diagnoseOk:$diagnoseOk},finalService:{running:$serviceAfterRunning},fixture:{status:"not-installed",reason:"TARGET_FIXTURE_NOT_AVAILABLE"}}'
