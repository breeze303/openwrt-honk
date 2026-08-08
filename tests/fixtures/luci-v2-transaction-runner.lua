local function read(path)
	local file = assert(io.open(path, "rb"))
	local value = file:read("*a")
	file:close()
	return value
end

local function write(path, value)
	local file = assert(io.open(path, "wb"))
	file:write(value)
	file:close()
	return true
end

local function access(path)
	local file = io.open(path, "rb")
	if file then file:close(); return true end
	return false
end

package.preload["nixio.fs"] = function()
	return {
		readfile = read, writefile = write, chmod = function() return true end,
		remove = os.remove, rename = os.rename, access = access,
		mkdir = function(path)
			return os.execute("mkdir -p " .. string.format("%q", path)) == 0
		end,
	}
end
package.preload["nixio"] = function()
	return {
		getpid = function() return 4343 end,
		open = function() return { lock = function() return true end, close = function() end } end,
		nanosleep = function() end,
	}
end
package.preload["luci.jsonc"] = function()
	return {
		parse = function(value)
			if value == "[tool-nodes]" then return { { name = "offline-node", protocol = "socks5" } } end
			if tostring(value):find('"ok":true', 1, true) then return { ok = true } end
			return nil
		end,
		stringify = function() return "{}" end,
	}
end
package.preload["luci.model.uci"] = function()
	return {
		cursor = function()
			return { get = function() return nil end }
		end,
	}
end

local alive, init_calls = arg[4] ~= "subscription-stopped", 0
package.preload["luci.sys"] = function()
	return {
		call = function(command)
			if command:find("pidof honk-core", 1, true) then return alive and 0 or 1 end
			local action = command:match("%s(restart)%s") or command:match("%s(start)%s") or command:match("%s(stop)%s")
			if action then
				init_calls = init_calls + 1
				if arg[4] == "failure" and init_calls == 1 then alive = false; return 1 end
				alive = action ~= "stop"
				return 0
			end
			return 0
		end,
		exec = function(command)
			if command:find(" sub %-%-format json") then return "[tool-nodes]" end
			if command:find("sha256sum", 1, true) then return "deadbeef  cache.sub\n" end
			return '{"ok":true}'
		end,
	}
end

for _, name in ipairs({ "config", "dns", "node", "mode", "subscription", "honk_network", "service" }) do
	local path = arg[1] .. "/luci-app-honk/luasrc/model/" .. name .. ".lua"
	package.preload["luci.model." .. name] = function() return dofile(path) end
end
local config = require "luci.model.config"
local service = require "luci.model.service"
local previous = read(arg[2])
local expected = config.file_revision(arg[2])
local candidate = previous:gsub("log_level: info", "log_level: debug")

package.preload["ubus"] = function()
	return { connect = function()
		return { call = function(_, object, _, argument)
			if object == "network.interface" then
				return { interface = {
					{ interface = "lan", l3_device = "br-lan", device = "br-lan", ["ipv4-address"] = {{ address = "192.0.2.1", mask = 24 }}, ["ipv6-address"] = {}, route = {} },
					{ interface = "wan", l3_device = "eth0.2", device = "eth0.2", ["ipv4-address"] = {{ address = "198.51.100.2", mask = 24 }}, ["ipv6-address"] = {}, route = {{ target = "0.0.0.0", metric = 10 }} },
				} }
			end
			if object == "network.device" and (argument.name == "br-lan" or argument.name == "eth0.2") then
				return { present = true, up = true, bridge = argument.name == "br-lan" }
			end
			return { present = false, up = false }
		end }
	end }
end

if arg[4] == "success" then
	local result, status = service.apply_content(candidate, expected, { fixture = "success" })
	assert(result and result.ok and not status, "success transaction failed")
	assert(read(arg[2]) == candidate, "candidate was not committed")
	print("transaction=committed")
	elseif arg[4] == "interfaces" then
		local invalid, invalid_status = service.apply_interfaces({ lanDevice = "br-lan", wanDevice = "eth0.2", dialMode = "domain++", logLevel = "verbose", expectedRevision = expected })
		assert(invalid and invalid.error.code == "LOG_LEVEL_INVALID" and invalid_status == 400, "invalid log level was accepted")
		local result, status = service.apply_interfaces({ lanDevice = "br-lan", wanDevice = "eth0.2", dialMode = "domain++", logLevel = "debug", expectedRevision = expected })
		assert(result and result.ok and not status, "interface transaction failed")
		assert(result.config and result.config:find("lan_interface: 'br%-lan'"), "interface response omitted LAN")
		assert(result.config:find("wan_interface: 'eth0%.2'"), "interface response omitted WAN")
		assert(result.config:find("dial_mode: 'domain%+%+'"), "interface response omitted dial mode")
		assert(result.config:find("log_level: 'debug'"), "interface response omitted log level")
		assert(read(arg[2]) == result.config, "interface response differs from committed configuration")
		print("interfaces=config-returned")
	elseif arg[4] == "clear-logs" then
		local log_path = assert(os.getenv("HONK_LOG_PATH"), "log path fixture missing")
		write(log_path, "sensitive log line\n")
		local result, status = service.clear_logs()
		assert(result and result.ok and result.cleared and not status, "log clear failed")
		assert(read(log_path) == "", "log file was not truncated")
		print("logs=cleared")
elseif arg[4] == "failure" then
	local result, status = service.apply_content(candidate, expected, { fixture = "failure" })
	assert(result and result.ok == false and result.error.code == "ROLLBACK" and status == 500, "rollback contract failed")
	assert(read(arg[2]) == previous, "previous configuration was not restored")
	print("transaction=restored")
elseif arg[4] == "clash-api" then
	local result, status = service.toggle_clash_api({ enabled = true, expectedRevision = expected })
	assert(result and result.ok and result.enabled and not status, "Clash API enable failed")
	assert(read(arg[2]):find("external_controller: '127%.0%.0%.1:9090'"), "Clash API controller was not enabled")
	local disabled_revision = config.file_revision(arg[2])
	result, status = service.toggle_clash_api({ enabled = false, expectedRevision = disabled_revision })
	assert(result and result.ok and not result.enabled and not status, "Clash API disable failed")
	assert(read(arg[2]):find("external_controller: ''"), "Clash API controller was not disabled")
	print("clash-api=toggle")
elseif arg[4] == "subscription-stopped" then
	local offline = previous:gsub("https://subscriber%.invalid/list%?token=REDACTED", "socks5://127.0.0.2:1080#offline-node")
	assert(offline ~= previous, "offline subscription fixture was not prepared")
	write(arg[2], offline)
	local result, status = service.refresh_subscription({ name = "fixture-sub" })
	assert(result and result.ok and not status, "stopped service subscription refresh failed")
	assert(result.cache and result.cache.nodeCount == 1, "stopped service did not persist subscription nodes")
	assert(result.runtimeRefresh == false, "stopped service unexpectedly used the runtime API")
	assert(not alive and init_calls == 0, "stopped service subscription refresh changed service state")
	print("subscription-refresh=offline-cache")
else
	local result, status = service.apply_content(candidate, "deadbeef", { fixture = "conflict" })
	assert(result and result.error.code == "REVISION_CONFLICT" and status == 409, "revision conflict contract failed")
	assert(read(arg[2]) == previous, "revision conflict changed configuration")
	print("transaction=conflict")
end
