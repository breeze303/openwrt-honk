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

package.preload["nixio.fs"] = function()
	return { readfile = read, writefile = write, chmod = function() return true end, remove = os.remove, rename = os.rename }
end
package.preload["nixio"] = function() return { getpid = function() return 4242 end } end
package.preload["luci.jsonc"] = function() return { parse = function() return nil end, stringify = function() return "{}" end } end

for _, name in ipairs({ "config", "dns", "node", "mode" }) do
	local path = arg[1] .. "/luci-app-honk/luasrc/model/" .. name .. ".lua"
	package.preload["luci.model." .. name] = function() return dofile(path) end
end
package.preload["luci.model.subscription"] = function()
	return { catalog = function() return {} end }
end
local mode = require "luci.model.mode"
local config = require "luci.model.config"
local source = read(arg[2])
local output_dir = arg[3]

local function routing_rule_count(content, rule)
	local count = 0
	for line in content:gmatch("[^\n]+") do
		if line == "\t" .. rule then count = count + 1 end
	end
	return count
end

local detected, managed = mode.detect(source)
assert(detected == "china-direct" and managed, "legacy china-direct migration was not detected")

local missing_node, missing_node_error = mode.compile(source, {
	mode = "global", nodeNames = { "missing-node" }, subscriptionNames = {}, deviceRules = {},
})
assert(not missing_node and missing_node_error:match("NODE_MISSING"), "missing node was not rejected")
local no_source, no_source_error = mode.compile(source, {
	mode = "global", nodeNames = {}, subscriptionNames = {}, deviceRules = {},
})
assert(not no_source and no_source_error == "PROXY_SOURCE_REQUIRED", "empty proxy source was not rejected")

for _, name in ipairs({ "china-direct", "gfwlist", "china-proxy", "global" }) do
	local compiled, err = mode.compile(source, {
		mode = name,
		nodeNames = { "fixture-node" },
		subscriptionNames = {},
		deviceRules = {},
	})
	assert(compiled, err)
	assert(compiled.candidate:find("pname(NetworkManager, systemd-resolved, dnsmasq) -> direct(must)", 1, true), "resolver process rule missing")
	assert(compiled.candidate:find("dip(geoip: private) -> direct", 1, true), "private rule missing")
	assert(routing_rule_count(compiled.candidate, "pname(NetworkManager, systemd-resolved, dnsmasq) -> direct(must)") == 1, "resolver process rule duplicated")
	assert(routing_rule_count(compiled.candidate, "dip(geoip: private) -> direct") == 1, "private rule duplicated")
	assert(compiled.candidate:find("direct-dns", 1, true), "new direct DNS name missing")
	assert(compiled.candidate:find("proxy-dns", 1, true), "new proxy DNS name missing")
	assert(compiled.candidate:find("bind: 'tcp+udp://127.0.0.1:1053'", 1, true), "dnsmasq listener bind missing")
	local projected_dns = require "luci.model.dns".current(compiled.candidate)
	assert(projected_dns.bind == "tcp+udp://127.0.0.1:1053", "generated DNS bind could not be read back")
	assert(projected_dns.direct == "udp://223.5.5.5:53", "generated direct DNS could not be read back")
	assert(projected_dns.proxy == "https://cloudflare-dns.com/dns-query", "generated proxy DNS could not be read back")
	local recompiled, recompile_error = mode.compile(compiled.candidate, {
		mode = name,
		nodeNames = { "fixture-node" },
		subscriptionNames = {},
		deviceRules = {},
	})
	assert(recompiled, recompile_error or "generated config could not be compiled again")
	assert(recompiled.candidate:find("bind: 'tcp+udp://127.0.0.1:1053'", 1, true), "DNS bind changed after recompilation")
	assert(routing_rule_count(recompiled.candidate, "pname(NetworkManager, systemd-resolved, dnsmasq) -> direct(must)") == 1, "resolver process rule changed after recompilation")
	assert(routing_rule_count(recompiled.candidate, "dip(geoip: private) -> direct") == 1, "private rule changed after recompilation")
	assert(not compiled.candidate:find("aliyun:", 1, true), "legacy DNS name leaked")
	assert(compiled.candidate:find("node {\n\tfixture-node: 'socks5://127.0.0.1:1080'\n}", 1, true), "node bytes changed")
	assert(compiled.candidate:find("subscription {", 1, true), "subscription section missing")
	assert(compiled.candidate:find("experimental {", 1, true), "experimental section missing")
	write(output_dir .. "/" .. name .. ".dae", compiled.candidate)
	print(name .. "=" .. config.revision(compiled.candidate))
end

local custom = source .. "\nfuture_feature {\n\tflag: true\n}\n"
local compiled, err = mode.compile(custom, { mode = "global", nodeNames = { "fixture-node" }, subscriptionNames = {}, deviceRules = {} })
assert(compiled, err)
assert(compiled.candidate:find("future_feature {\n\tflag: true\n}", 1, true), "unknown section was not preserved")
print("preservation=ok")

local custom_route = source:gsub("domain%(geosite: cn%) %-%> direct", "domain(geosite: custom) -> direct")
	:gsub("fallback: quick%-proxy", "sip(192.0.2.10) -> direct\n\tfallback: quick-proxy")
local takeover, takeover_error = mode.compile(custom_route, { mode = "global", nodeNames = { "fixture-node" }, subscriptionNames = {}, deviceRules = {} })
assert(takeover and takeover.requiresTakeover, takeover_error or "custom routing did not require takeover")
print("takeover=required")
