#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
presets='gfwlist,china-direct,global,direct'
evidence="$repo_root/.cache/evidence/target-harness"
synthetic=false
failure=''
target=${HONK_TARGET_SSH:-}
password_fd=${HONK_TARGET_PASSWORD_FD:-}
package=${HONK_TARGET_PACKAGE:-}
luci_package=${HONK_TARGET_LUCI_PACKAGE:-}
while [ "$#" -gt 0 ]; do
	case "$1" in
		--preset) presets=$2; shift 2 ;;
		--evidence) evidence=$2; shift 2 ;;
		--synthetic) synthetic=true; shift ;;
		--failure) failure=$2; shift 2 ;;
		--target) target=$2; shift 2 ;;
		--password-fd) password_fd=$2; shift 2 ;;
		--package) package=$2; shift 2 ;;
		--luci-package) luci_package=$2; shift 2 ;;
		*) echo "usage: $0 --preset LIST --evidence DIR [--synthetic] [--failure CASE] [--target USER@HOST --password-fd FD --package APK]" >&2; exit 64 ;;
	esac
done
mkdir -p "$evidence/failures"
chmod 700 "$evidence"
IFS=',' read -r -a selected <<<"$presets"
for preset in "${selected[@]}"; do
	case "$preset" in gfwlist|china-direct|global|direct) ;; *) echo "unknown preset: $preset" >&2; exit 64 ;; esac
done

if [ "$synthetic" != true ] && [ -z "$target" ]; then
	jq -n --arg presets "$presets" '{schemaVersion:"honk.target-harness.v1",ok:false,status:"blocked",reason:"TARGET_NOT_CONFIGURED",presets:($presets|split(",")),publicEgressGuard:"not-installed"}' >"$evidence/receipt.json"
	echo "no target configured; rerun with --target/HONK_TARGET_SSH or --synthetic" >&2
	exit 2
fi

if [ "$synthetic" != true ]; then
	[ -n "$password_fd" ] || {
		jq -n --arg presets "$presets" '{schemaVersion:"honk.target-harness.v1",ok:false,status:"blocked",reason:"TARGET_PASSWORD_FD_REQUIRED",presets:($presets|split(",")),publicEgressGuard:"not-installed"}' >"$evidence/receipt.json"
		echo "real target mode requires --password-fd/HONK_TARGET_PASSWORD_FD" >&2
		exit 2
	}
	[ -n "$package" ] || {
		jq -n --arg presets "$presets" '{schemaVersion:"honk.target-harness.v1",ok:false,status:"blocked",reason:"TARGET_PACKAGE_REQUIRED",presets:($presets|split(",")),publicEgressGuard:"not-installed"}' >"$evidence/receipt.json"
		echo "real target mode requires the built honk APK" >&2
		exit 2
	}
	mkdir -p "$evidence/real-target"
	set +e
	smoke_args=(--target "$target" --password-fd "$password_fd" --package "$package")
	[ -z "$luci_package" ] || smoke_args+=(--luci-package "$luci_package")
	smoke_args+=(--evidence "$evidence/real-target")
	"$repo_root/.github/scripts/target-smoke.sh" "${smoke_args[@]}"
	smoke_rc=$?
	set -e
	cat >"$evidence/fixture-manifest.json" <<'JSON'
{
  "schemaVersion": "honk.target-fixture.v1",
  "status": "not-installed",
  "network": {"lan": null, "wan": null, "services": null},
  "dns": {"aliyun": "223.5.5.5:53", "google": "8.8.8.8:53", "status": "not-installed"},
  "publicEgress": {"guard": "not-proven", "managementInterfaceExcluded": true},
  "membership": {"status": "not-collected", "source": "openwrt-v2ray-packages-required"},
  "usesTestDomains": false
}
JSON
	for preset in "${selected[@]}"; do
		jq -n --arg preset "$preset" '{schemaVersion:"honk.target-case.v1",preset:$preset,status:"blocked",reason:"TARGET_FIXTURE_NOT_AVAILABLE",ok:false,rollback:{required:true,managementInterfacePreserved:true}}' >"$evidence/$preset.json"
	done
	jq -n --arg presets "$presets" --argjson smokeRc "$smoke_rc" --argjson smokeOk "$(jq -r '.ok // false' "$evidence/real-target/package-smoke.json" 2>/dev/null || printf false)" \
		'{schemaVersion:"honk.target-harness.v1",ok:false,status:(if $smokeOk then "partial" else "blocked" end),presets:($presets|split(",")),packageSmoke:$smokeOk,packageSmokeExit:$smokeRc,fixture:"not-installed",publicEgressGuard:"not-proven",reason:"TARGET_DATA_PLANE_REQUIRES_ISOLATED_FIXTURE",restoreManifest:"real-target/package-smoke.json"}' \
		>"$evidence/receipt.json"
	printf 'target harness cases=%s mode=target packageSmokeExit=%s\n' "${#selected[@]}" "$smoke_rc"
	exit 2
fi

cat >"$evidence/fixture-manifest.json" <<'JSON'
{
  "schemaVersion": "honk.target-fixture.v1",
  "network": {"lan": "hkFIXTURE-lan", "wan": "hkFIXTURE-wan", "services": "hkFIXTURE-services", "publicEgress": "DROP"},
  "dns": {"aliyun": "223.5.5.5:53", "google": "8.8.8.8:53"},
  "membership": {"gfwMember": "v2ray-geosite-required", "nonGfwMember": "v2ray-geosite-required", "cnMember": "v2ray-geosite-required", "nonCnMember": "v2ray-geosite-required", "cnIpMember": "v2ray-geoip-required", "nonCnIpMember": "v2ray-geoip-required"},
  "usesTestDomains": false
}
JSON

for preset in "${selected[@]}"; do
	case "$preset" in
		gfwlist)
			direct=1; proxy=1; dns="gfw->google,other->aliyun"; rule="gfwMember=proxy,nonGfwMember=direct" ;;
		china-direct)
			direct=2; proxy=1; dns="cn->aliyun,other->google"; rule="cnMember/privateIpMember=direct,nonCnMember=proxy" ;;
		global)
			direct=1; proxy=2; dns="all->google"; rule="ordinary=proxy,private=direct" ;;
		direct)
			direct=3; proxy=0; dns="all->aliyun"; rule="ordinary=direct" ;;
	esac
	status=synthetic-fixture
	if [ "$failure" = "$preset" ]; then
		status=restored
		printf '%s\n' "{\"preset\":\"$preset\",\"ok\":false,\"stage\":\"rollback-in-progress\",\"result\":\"restored\",\"publicEgress\":0}" >"$evidence/failures/$preset.json"
	fi
	jq -n --arg preset "$preset" --arg status "$status" --arg dns "$dns" --arg rule "$rule" --argjson direct "$direct" --argjson proxy "$proxy" \
		'{schemaVersion:"honk.target-case.v1",preset:$preset,status:$status,synthetic:($status=="synthetic-fixture"),expected:{direct:$direct,proxy:$proxy,dns:$dns,rule:$rule,publicEgress:0},rollback:{onFailure:true,managementInterfacePreserved:true},ok:true}' \
		>"$evidence/$preset.json"
done

mode=synthetic
[ "$synthetic" = true ] || mode=target
jq -n --arg presets "$presets" --arg mode "$mode" \
	'{schemaVersion:"honk.target-harness.v1",ok:true,status:$mode,presets:($presets|split(",")),publicEgressGuard:{fixtureOnly:true,managementExcluded:true},restoreManifest:"fixture-manifest.json"}' \
	>"$evidence/receipt.json"
printf 'target harness cases=%s mode=%s\n' "${#selected[@]}" "$mode"
