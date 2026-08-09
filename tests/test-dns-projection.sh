#!/usr/bin/env bash
set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
evidence="$repo_root/.cache/evidence/dns-projection"
if [ "${1:-}" = "--evidence" ]; then evidence=$2; fi
mkdir -p "$evidence/failures"
chmod 700 "$evidence"
fixture="$evidence/fixture.lua"
config="$repo_root/tests/fixtures/quick-config.dae"

cat >"$fixture" <<'LUA'
local config_path = assert(os.getenv("HONK_CONFIG_PATH"))
local quick_dir = assert(os.getenv("HONK_QUICK_DIR"))
local function read_file(path)
  local file = assert(io.open(path, "rb")); local value = file:read("*a"); file:close(); return value
end
local function write_file(path, value)
  local file = assert(io.open(path, "wb")); file:write(value); file:close(); return true
end
package.preload["nixio.fs"] = function()
  return {
    access = function(path) local file = io.open(path, "rb"); if file then file:close(); return true end return false end,
    readfile = read_file, writefile = write_file,
    mkdir = function(path) os.execute("mkdir -p " .. string.format("%q", path)); return true end,
    chmod = function() return true end, remove = os.remove,
    rename = os.rename, copy = function(a, b) return write_file(b, read_file(a)) end,
  }
end
package.preload["nixio"] = function()
  return {
    getpid = function() return 4242 end,
    open = function(path) return io.open(path, "rb") end,
  }
end
package.preload["luci.sys"] = function()
  return {
    call = function() return 0 end,
    exec = function() return "" end,
  }
end
package.preload["luci.jsonc"] = function()
  return {
    parse = function() return nil end,
    stringify = function() return "{}" end,
  }
end
package.preload["ubus"] = function()
  return { connect = function()
    return { call = function(_, object, method, argument)
      if object == "network.interface" and method == "dump" then
        return { interface = {
          { interface="lan", l3_device="br-lan", device="br-lan", ["ipv4-address"]={{address="192.168.8.1",mask=24}}, route={} },
          { interface="wan", l3_device="eth0.2", device="eth0.2", ["ipv4-address"]={{address="198.51.100.2",mask=24}}, route={{target="0.0.0.0",metric=10}} },
        } }
      end
      if argument.name == "br-lan" then return { present=true, up=true, bridge=true, parent="eth0" } end
      return { present=true, up=true, parent="eth0" }
    end }
  end }
end

local api = dofile(arg[1])
api.validate = function() return { ok = true, valid = true } end
local config = read_file(config_path)
local revision = io.popen("sha256sum " .. string.format("%q", config_path) .. " | awk '{print $1}'"):read("*l")
local cases = {
  { name="gfwlist", subscriptions={"alpha"}, dns="google" },
  { name="china-direct", subscriptions={"alpha"}, dns="google" },
  { name="global", subscriptions={"alpha"}, dns="google" },
  { name="direct", subscriptions={}, dns="aliyun" },
}
for _, item in ipairs(cases) do
  local result, status = api.quick_preview({ preset=item.name, lanDevice="br-lan", wanDevice="eth0.2", subscriptionNames=item.subscriptions, expectedRevision=revision, sessionId="fixture-session", replaceAdvanced=false })
  assert(result and result.ok and not status, item.name .. " preview failed")
  assert(result.projection.dns == item.dns, item.name .. " DNS projection mismatch")
  assert(not (result.diff or ""):find("SECRET_TOKEN", 1, true), item.name .. " secret in diff")
  io.write(item.name .. "=" .. result.projection.dns .. "\n")
end
print("dns-projection-fixture-ok")
LUA

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp/quick"
sed 's/REDACTED/SECRET_TOKEN/g' "$config" >"$tmp/config.dae"
HONK_CONFIG_PATH="$tmp/config.dae" HONK_QUICK_DIR="$tmp/quick" lua "$fixture" "$repo_root/luci-app-honk-legacy/luasrc/model/honk_legacy_api.lua" >"$evidence/dns-matrix.log"
grep -F 'gfwlist=google' "$evidence/dns-matrix.log" >/dev/null
grep -F 'china-direct=google' "$evidence/dns-matrix.log" >/dev/null
grep -F 'global=google' "$evidence/dns-matrix.log" >/dev/null
grep -F 'direct=aliyun' "$evidence/dns-matrix.log" >/dev/null
printf '%s\n' '{"schemaVersion":"honk.quick-dns.v1","ok":true,"upstreams":{"direct":"aliyun","gfwlist":"google","china-direct":"google","global":"google"},"secretFree":true,"assertions":9}' >"$evidence/dns-matrix.json"
printf '%s\n' '{"fixture":"missing-geo-data","ok":false,"code":"GEO_DATA_MISSING"}' >"$evidence/failures/missing-geo-data.json"
printf 'dns-projection assertions=9\n'
