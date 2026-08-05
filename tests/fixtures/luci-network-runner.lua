local function read(path)
	local file = assert(io.open(path, "rb"))
	local value = file:read("*a")
	file:close()
	return value
end

local scenario = os.getenv("HONK_NETWORK_FIXTURE") or "happy"
package.preload["nixio.fs"] = function()
	return { readfile = read, writefile = function() return true end, chmod = function() return true end, remove = function() return true end, rename = function() return true end }
end
package.preload["nixio"] = function() return { getpid = function() return 7 end } end
package.preload["luci.jsonc"] = function() return { parse = function() return nil end, stringify = function() return "{}" end } end
package.preload["luci.model.config"] = function() return dofile(arg[2]:gsub("/tests/fixtures/.*$", "/luci-app-honk/luasrc/model/config.lua")) end
package.preload["ubus"] = function()
	local wan_device = scenario == "same-device" and "br-lan" or "eth0.2"
	if scenario == "missing-wan" then wan_device = "" end
	return { connect = function()
		return { call = function(_, object, method, argument)
			if object == "network.interface" then
				return { interface = {
					{ interface = "lan", l3_device = scenario == "no-l3" and "" or "br-lan", device = "br-lan", ["ipv4-address"] = scenario == "ipv6-only" and {} or {{ address = "192.0.2.1", mask = 24 }}, ["ipv6-address"] = {{ address = "fd00::1", mask = 64 }}, route = {} },
					{ interface = "wan", l3_device = wan_device, device = "eth0.2", ["ipv4-address"] = {{ address = "198.51.100.2", mask = 24 }}, ["ipv6-address"] = {}, route = scenario == "missing-wan" and {} or {{ target = "0.0.0.0", metric = 10 }} },
				} }
			end
			if argument.name == "br-lan" or argument.name == "eth0.2" then return { present = true, up = true, bridge = argument.name == "br-lan" } end
			return { present = false, up = false }
		end }
	end }
end

local network = dofile(arg[1])
local discovery = network.discover()
assert(discovery.ok, "discovery failed")
if scenario == "happy" then
	assert(discovery.recommended.lan == "br-lan" and discovery.recommended.wan == "eth0.2", "recommendation mismatch")
	assert(not discovery.ambiguous, "happy discovery is ambiguous")
	for _, item in ipairs(discovery.candidates) do assert(item.l3Device ~= "lo", "loopback must not be selectable") end
	local selected = assert(network.validate_selection(discovery, "br-lan", "eth0.2", "domain++"))
	assert(not network.validate_selection(discovery, "br-lan", "eth0.2", "invalid"), "invalid dial mode accepted")
	local updated = assert(network.update_global(read(arg[2]), selected))
	assert(updated:find("lan_interface: 'br%-lan'"), "LAN was not updated")
	assert(updated:find("wan_interface: 'eth0%.2'"), "WAN was not updated")
	assert(updated:find("dial_mode: 'domain%+%+'"), "dial mode was not updated")
	for _ = 1, 4 do
		updated = assert(network.update_global(updated, selected))
	end
	assert(select(2, updated:gsub("lan_interface:", "")) == 1, "LAN key was duplicated")
	assert(select(2, updated:gsub("wan_interface:", "")) == 1, "WAN key was duplicated")
	assert(select(2, updated:gsub("dial_mode:", "")) == 1, "dial mode key was duplicated")
elseif scenario == "same-device" then
	assert(discovery.ambiguous, "same device was accepted")
elseif scenario == "no-l3" then
	assert(discovery.interfaces[1].safe == false and discovery.interfaces[1].reasonCodes[1] == "L3_DEVICE_MISSING", "missing L3 was not rejected")
elseif scenario == "missing-wan" then
	assert(discovery.recommended.wan == nil and discovery.ambiguous, "missing WAN was accepted")
elseif scenario == "ipv6-only" then
	assert(discovery.interfaces[1].addresses[1].family == "ipv6", "IPv6 address was not normalized")
end
print("network-model-ok scenario=" .. scenario)
