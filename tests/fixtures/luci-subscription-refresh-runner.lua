local function read(path)
	local file = assert(io.open(path, "rb"))
	local value = file:read("*a")
	file:close()
	return value
end

package.preload["nixio.fs"] = function()
	return { readfile = read }
end
package.preload["nixio"] = function()
	return {}
end
package.preload["luci.jsonc"] = function()
	return { parse = function() return nil end }
end
package.preload["luci.sys"] = function()
	return {
		call = function(command)
			local file = assert(io.open(arg[3], "ab"))
			file:write(command, "\n")
			file:close()
			if command:find("pidof honk%-core", 1, false) then return 1 end
			return command:find(" start ", 1, true) and 0 or 1
		end,
	}
end

package.preload["luci.model.config"] = function()
	return dofile(arg[1] .. "/luci-app-honk/luasrc/model/config.lua")
end
local node = dofile(arg[1] .. "/luci-app-honk/luasrc/model/node.lua")
local ok, detail = node.refresh_subscription(read(arg[2]), "fixture-sub")
assert(ok, detail or "subscription refresh did not use the native service path")
local command = read(arg[3])
assert(command:find("'" .. os.getenv("HONK_INIT_PATH") .. "' start", 1, true), "native start was not requested")
print("subscription-refresh=native-service")
