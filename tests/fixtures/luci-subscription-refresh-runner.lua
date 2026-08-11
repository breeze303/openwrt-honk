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

local edge = [[subscription {
	legacy: 'https://legacy.invalid/list'
	1 {
		url: 'https://numeric.invalid/list'
		update_interval: 3600
		enabled: false
	}
	work.main {
		url: 'https://dotted.invalid/list'
		update_interval: 7200
		enabled: true
	}
	url {
		url: 'https://named-url.invalid/list'
		update_interval: 86400
		enabled: true
	}
}
]]
local edge_catalog = node.catalog(edge).subscriptions
assert(#edge_catalog == 4, "nested subscription properties leaked into the catalog")
assert(edge_catalog[1].name == "1" and edge_catalog[1].updateInterval == 3600 and not edge_catalog[1].enabled, "numeric subscription metadata was not parsed")
assert(edge_catalog[2].name == "legacy" and edge_catalog[3].name == "url" and edge_catalog[4].name == "work.main", "mixed subscription formats were not preserved")
assert(node.subscription_url(edge, "work.main") == "https://dotted.invalid/list", "dotted subscription URL lookup failed")
local without_url, url_remove_error = node.mutate(edge, { action = "remove-subscription", name = "url" })
assert(without_url and not url_remove_error and not node.subscription_url(without_url, "url"), "reserved-field subscription removal failed")
assert(node.subscription_url(without_url, "work.main") == "https://dotted.invalid/list", "subscription removal damaged an adjacent URL field")
local removed, remove_error = node.mutate(without_url, { action = "remove-subscription", name = "1" })
assert(removed and not remove_error and not node.subscription_url(removed, "1"), "numeric subscription removal failed")
assert(node.subscription_url(removed, "work.main") == "https://dotted.invalid/list", "subscription removal damaged an adjacent block")

local ok, detail = node.refresh_subscription(content, "fixture-sub")
assert(not ok and detail == "CLASH_API_UNAVAILABLE", "subscription refresh must not start Honk when the runtime API is absent")
local log = io.open(arg[3], "rb")
if log then
	local command = log:read("*a")
	log:close()
	assert(not command:find(" start", 1, true) and not command:find(" restart", 1, true), "runtime API fallback started Honk")
end
print("subscription-refresh=runtime-api-only")
