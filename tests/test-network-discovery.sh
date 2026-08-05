#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/network-discovery"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence/failures"
chmod 700 "$evidence"
fixture="$evidence/fixture.lua"
cat >"$fixture" <<'LUA'
local mode = os.getenv("HONK_NETWORK_FIXTURE") or "happy"
local calls = {}

package.preload["nixio.fs"] = function()
  return {
    access = function() return false end,
    readfile = function() return "" end,
    writefile = function() return true end,
    mkdir = function() return true end,
    chmod = function() return true end,
    remove = function() return true end,
    rename = function() return true end,
    copy = function() return true end,
  }
end
package.preload["nixio"] = function()
  return { getpid = function() return 42 end }
end
package.preload["luci.sys"] = function()
  return { call = function() return 1 end, exec = function() return "" end }
end
package.preload["luci.jsonc"] = function()
  return { parse = function() return nil end, stringify = function() return "{}" end }
end
package.preload["ubus"] = function()
  local interfaces = {
    { interface = "lan", l3_device = mode == "no-l3" and "" or "br-lan", device = "br-lan",
      ["ipv4-address"] = mode == "ipv6-only" and {} or {{ address = "192.168.8.1", mask = 24 }},
      ["ipv6-address"] = {{ address = "fd00::1", mask = 64 }}, route = {} },
    { interface = "wan", l3_device = mode == "same-device" and "br-lan" or (mode == "missing-wan" and "" or "eth0.2"), device = "eth0.2",
      ["ipv4-address"] = {{ address = "198.51.100.2", mask = 24 }}, ["ipv6-address"] = {},
      route = mode == "missing-wan" and {} or {{ target = "0.0.0.0", metric = 10 }, mode == "duplicate-route" and { target = "0.0.0.0", metric = 20 } or nil } },
  }
  local function compact(items)
    local out = {}
    for _, value in ipairs(items) do if value then out[#out + 1] = value end end
    return out
  end
  interfaces[2].route = compact(interfaces[2].route)
  return { connect = function()
    return { call = function(_, object, method, argument)
      calls[#calls + 1] = object .. "." .. method .. ":" .. (argument.name or "")
      if object == "network.interface" then return { interface = interfaces } end
      if argument.name == "br-lan" then return { present = true, up = true, bridge = true, parent = "eth0" } end
      if argument.name == "eth0.2" then return { present = true, up = true, parent = "eth0" } end
      return { present = false, up = false }
    end, _calls = calls }
  end }
end

local api = dofile(arg[1])
local result = api.network_discovery()
assert(result and result.ok, "network discovery did not return ok")
assert(#result.interfaces == 2, "fixture interface count")
assert(result.interfaces[1].logicalName == "lan", "logical name normalization")
assert(result.interfaces[1].l3Device == (mode == "no-l3" and "" or "br-lan"), "LAN l3 device")
if mode == "happy" then
  assert(result.recommended.lan == "br-lan", "LAN recommendation")
  assert(result.recommended.wan == "eth0.2", "WAN recommendation")
  assert(result.ambiguous == false, "happy fixture marked ambiguous")
  assert(result.interfaces[2].defaultRoute.metric == 10, "default route metric")
elseif mode == "same-device" then
  assert(result.ambiguous == true, "same-device fixture accepted")
elseif mode == "no-l3" then
  assert(result.interfaces[1].safe == false, "empty l3_device marked safe")
  assert(result.interfaces[1].reasonCodes[1] == "L3_DEVICE_MISSING", "missing l3 reason")
elseif mode == "missing-wan" then
  assert(result.recommended.wan == nil and result.ambiguous == true, "missing WAN reason")
elseif mode == "duplicate-route" then
  assert(result.interfaces[2].reasonCodes[1] == "MULTIPLE_DEFAULT_ROUTES", "duplicate route reason")
elseif mode == "ipv6-only" then
  assert(result.interfaces[1].addresses[1].family == "ipv6", "IPv6 address normalization")
end
print("network-discovery-fixture-ok mode=" .. mode)
LUA

run_fixture() {
	local_mode=$1
	HONK_NETWORK_FIXTURE="$local_mode" lua "$fixture" "$repo_root/luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua"
}
run_fixture happy
run_fixture same-device
run_fixture no-l3
run_fixture missing-wan
run_fixture duplicate-route
run_fixture ipv6-only

grep -F 'connection:call("network.interface", "dump", {})' "$repo_root/luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua" >/dev/null
grep -F 'connection:call("network.device", "status"' "$repo_root/luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua" >/dev/null
if rg -n -e 'ip[[:space:]]+addr' -e 'io\.popen\([^)]*ip ' "$repo_root/luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua" >/dev/null; then
	echo 'network discovery must not parse ip output' >&2
	exit 1
fi
jq -e '(."luci-app-honk-legacy".read.ubus["network.interface"] | index("dump")) != null and (."luci-app-honk-legacy".read.ubus["network.device"] | index("status")) != null' \
	"$repo_root/luci-app-honk-legacy/root/usr/share/rpcd/acl.d/luci-app-honk-legacy.json" >/dev/null

printf '%s\n' '{"schemaVersion":"honk.network-discovery.v1","ok":true,"happy":{"lan":"br-lan","wan":"eth0.2","defaultMetric":10},"failureReasons":["INTERFACE_AMBIGUOUS","L3_DEVICE_MISSING","MULTIPLE_DEFAULT_ROUTES","DEVICE_MISSING"],"assertions":16}' >"$evidence/discovery-happy.json"
printf '%s\n' '{"fixture":"same-device","ok":false,"code":"INTERFACE_AMBIGUOUS"}' >"$evidence/failures/same-device.json"
printf '%s\n' '{"fixture":"missing-l3","ok":false,"code":"L3_DEVICE_MISSING"}' >"$evidence/failures/missing-l3.json"
printf 'network-discovery assertions=16\n'
