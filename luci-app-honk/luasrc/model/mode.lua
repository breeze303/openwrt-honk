local config = require "luci.model.config"
local dns = require "luci.model.dns"
local node = require "luci.model.node"

local M = {}

M.MODES = {
	["china-direct"] = { label = "国内直连", geoSite = { "cn" }, geoIp = { "private", "cn" } },
	gfwlist = { label = "GFW", geoSite = { "gfw" }, geoIp = { "private" } },
	["china-proxy"] = { label = "国内代理", geoSite = { "cn" }, geoIp = { "private", "cn" } },
	global = { label = "全局模式", geoSite = {}, geoIp = { "private" } },
}

local function routing_body(content)
	local section = config.section(content, "routing")
	return section and config.section_body(content, section) or ""
end

local function marker_mode(content)
	local value = tostring(content or ""):match("luci%-app%-honk%s+managed:%s*v1%s+mode=([%w_-]+)")
	return M.MODES[value] and value or nil
end

local function fallback(body)
	for line in tostring(body or ""):gmatch("[^\n]+") do
		local value = line:gsub("#.*$", ""):match("^%s*fallback%s*:%s*([%w_.-]+)")
		if value then return value end
	end
	return nil
end

function M.detect(content)
	local marked = marker_mode(content)
	if marked then return marked, true end
	local body = routing_body(content)
	local target = fallback(body)
	if not target then return nil, false end
	if body:match("domain%s*%(%s*geosite:%s*gfw%s*%)%s*%-%>%s*[%w_.-]+") and target == "direct" then
		return "gfwlist", true
	end
	local china_direct = body:match("dip%s*%(%s*geoip:%s*cn%s*%)%s*%-%>%s*direct") and body:match("domain%s*%(%s*geosite:%s*cn%s*%)%s*%-%>%s*direct")
	if china_direct and target ~= "direct" then return "china-direct", true end
	local china_ip_target = body:match("dip%s*%(%s*geoip:%s*cn%s*%)%s*%-%>%s*([%w_.-]+)")
	local china_domain_target = body:match("domain%s*%(%s*geosite:%s*cn%s*%)%s*%-%>%s*([%w_.-]+)")
	if china_ip_target and china_ip_target ~= "direct" and china_domain_target == china_ip_target and target == "direct" then
		return "china-proxy", true
	end
	local significant = 0
	for line in body:gmatch("[^\n]+") do
		local clean = config.trim(line:gsub("#.*$", ""))
		if clean:find("->", 1, true) and not clean:match("^dip%s*%(%s*geoip:%s*private%s*%)%s*%-%>%s*direct%(must%)$") then significant = significant + 1 end
	end
	if target ~= "direct" and significant == 0 then return "global", true end
	return nil, false
end

local function selected_group(content)
	local section = config.section(content, "group")
	if not section then return { nodes = {}, subscriptions = {} } end
	local body = config.section_body(content, section)
	local parsed = config.parse(body)
	if not parsed then return { nodes = {}, subscriptions = {} } end
	local group
	for _, candidate in ipairs(parsed.sections) do
		if candidate.name == "honk-proxy" or candidate.name == "quick-proxy" then group = candidate; break end
	end
	if not group then return { nodes = {}, subscriptions = {} } end
	local group_body = config.section_body(body, group)
	local result, seen = { nodes = {}, subscriptions = {} }, {}
	for line in group_body:gmatch("[^\n]+") do
		local kind, arguments = line:match("^%s*filter%s*:%s*(name)%s*%((.-)%)%s*$")
		if not kind then kind, arguments = line:match("^%s*filter%s*:%s*(subscription)%s*%((.-)%)%s*$") end
		if kind and arguments then
			for value in arguments:gmatch("['\"]([^'\"]+)['\"]") do
				local key = kind .. ":" .. value
				if not seen[key] then
					local list = kind == "name" and result.nodes or result.subscriptions
					list[#list + 1], seen[key] = value, true
				end
			end
		end
	end
	return result
end

function M.selected(content)
	return selected_group(content)
end

function M.device_rules(content)
	local result = {}
	for line in routing_body(content):gmatch("[^\n]+") do
		local value, outbound = line:match("^%s*sip%s*%(([^)]+)%)%s*%-%>%s*([%w_.-]+)%s*$")
		if value then result[#result + 1] = { kind = "ip", value = config.trim(value), outbound = outbound == "direct" and "direct" or "proxy" } end
		value, outbound = line:match("^%s*mac%s*%(([^)]+)%)%s*%-%>%s*([%w_.-]+)%s*$")
		if value then result[#result + 1] = { kind = "mac", value = config.trim(value), outbound = outbound == "direct" and "direct" or "proxy" } end
	end
	return result
end

local function render_global(content)
	local section = config.section(content, "global")
	if section then
		local body = config.section_body(content, section)
		if config.trim(body) ~= "" then return "global {" .. body .. "}" end
	end
	return table.concat({
		"global {",
		"\twan_interface: auto",
		"\tlan_interface: auto",
		"\tlog_level: info",
		"\tdial_mode: domain",
		"\tauto_config_kernel_parameter: true",
		"}",
	}, "\n")
end

local function normalize_device_rules(rules)
	if type(rules) ~= "table" or #rules > 64 then return nil, "DEVICE_RULES_INVALID" end
	local result, seen = {}, {}
	for _, rule in ipairs(rules) do
		if type(rule) ~= "table" or (rule.kind ~= "ip" and rule.kind ~= "mac") or (rule.outbound ~= "direct" and rule.outbound ~= "proxy") then
			return nil, "DEVICE_RULE_INVALID"
		end
		local value = config.trim(rule.value)
		if rule.kind == "ip" then
			if not value:match("^[%x%.:/]+$") then return nil, "DEVICE_IP_INVALID" end
		elseif not value:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
			return nil, "DEVICE_MAC_INVALID"
		end
		local key = rule.kind .. ":" .. value
		if seen[key] then return nil, "DEVICE_RULE_DUPLICATE" end
		seen[key] = true
		result[#result + 1] = { kind = rule.kind, value = value, outbound = rule.outbound }
	end
	return result, nil
end

local function render_group(selected)
	local lines = { "group {", "\thonk-proxy {" }
	for _, line in ipairs(node.filters(selected)) do lines[#lines + 1] = line end
	lines[#lines + 1] = "\t\tpolicy: selector"
	if #(selected.nodes or {}) == 1 then lines[#lines + 1] = "\t\tdefault: " .. config.dae_quote(selected.nodes[1]) end
	lines[#lines + 1] = "\t\tfinal: direct"
	lines[#lines + 1] = "\t}"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n")
end

local function render_routing(mode, device_rules)
	local lines = { "routing {", "\tdip(geoip: private) -> direct(must)" }
	for _, rule in ipairs(device_rules) do
		local condition = rule.kind == "ip" and "sip(" .. rule.value .. ")" or "mac(" .. rule.value .. ")"
		lines[#lines + 1] = "\t" .. condition .. " -> " .. (rule.outbound == "direct" and "direct" or "honk-proxy")
	end
	if mode == "gfwlist" then
		lines[#lines + 1] = "\tdomain(geosite: gfw) -> honk-proxy"
		lines[#lines + 1] = "\tfallback: direct"
	elseif mode == "china-direct" then
		lines[#lines + 1] = "\tdip(geoip: cn) -> direct"
		lines[#lines + 1] = "\tdomain(geosite: cn) -> direct"
		lines[#lines + 1] = "\tfallback: honk-proxy"
	elseif mode == "china-proxy" then
		lines[#lines + 1] = "\tdip(geoip: cn) -> honk-proxy"
		lines[#lines + 1] = "\tdomain(geosite: cn) -> honk-proxy"
		lines[#lines + 1] = "\tfallback: direct"
	elseif mode == "global" then
		lines[#lines + 1] = "\tfallback: honk-proxy"
	end
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n"), lines
end

function M.compile(content, input)
	if type(input) ~= "table" or not M.MODES[input.mode] then return nil, "MODE_UNKNOWN" end
	local parsed, parse_error = config.parse(content)
	if not parsed then return nil, "CONFIG_PARSE_FAILED:" .. tostring(parse_error) end
	local runtime = node.runtime_catalog(content)
	local runtime_names = {}
	for _, item in ipairs(runtime.nodes or {}) do runtime_names[#runtime_names + 1] = item.name end
	local selected, source_error = node.select(content, {
		nodeNames = input.nodeNames or {}, subscriptionNames = input.subscriptionNames or {},
		runtimeNodeNames = runtime_names,
	})
	if not selected then return nil, source_error end
	local device_rules, device_error = normalize_device_rules(input.deviceRules or M.device_rules(content))
	if not device_rules then return nil, device_error end
	local current_dns = dns.current(content)
	local dns_block, dns_error, dns_rules = dns.render(input.mode, {
		direct = input.directDns or current_dns.direct,
		proxy = input.proxyDns or current_dns.proxy,
	})
	if not dns_block then return nil, dns_error end
	local routing_block, routing_lines = render_routing(input.mode, device_rules)
	local marker = "# luci-app-honk managed: v1 mode=" .. input.mode
	local candidate, replace_error = config.replace_managed(content, {
		render_global(content), render_group(selected), routing_block, dns_block,
	}, marker)
	if not candidate then return nil, "CONFIG_REBUILD_FAILED:" .. tostring(replace_error) end
	local old_mode, recognized = M.detect(content)
	return {
		candidate = candidate,
		mode = input.mode,
		previousMode = old_mode,
		requiresTakeover = not recognized,
		selected = selected,
		deviceRules = device_rules,
		routingLines = routing_lines,
		dnsRules = dns_rules,
	}, nil
end

function M.geo_requirements(mode)
	return M.MODES[mode]
end

return M
