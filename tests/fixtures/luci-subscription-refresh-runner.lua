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
local content = read(arg[2])
assert(node.subscription_url(content, "fixture-sub") == "https://subscriber.invalid/list?token=REDACTED", "private subscription URL lookup failed")
assert(node.catalog(content).subscriptions[1].url == nil, "public subscription catalog exposed the URL")
local ok, detail = node.refresh_subscription(content, "fixture-sub")
assert(not ok and detail == "CLASH_API_UNAVAILABLE", "subscription refresh must not start Honk when the runtime API is absent")
local log = io.open(arg[3], "rb")
if log then
	local command = log:read("*a")
	log:close()
	assert(not command:find(" start", 1, true) and not command:find(" restart", 1, true), "runtime API fallback started Honk")
end
print("subscription-refresh=runtime-api-only")
