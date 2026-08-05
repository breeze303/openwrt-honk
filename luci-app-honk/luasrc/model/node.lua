local config = require "luci.model.config"
local jsonc = require "luci.jsonc"

local M = {}

M.DELAY_URL = "https://www.gstatic.com/generate_204"
M.DELAY_TIMEOUT = 8000

local RESERVED = { direct = true, block = true, ["honk-proxy"] = true, ["quick-proxy"] = true }
local NODE_SCHEMES = {
	ss = true, ss2022 = true, vmess = true, vless = true, trojan = true,
	tuic = true, hysteria2 = true, anytls = true, juicity = true,
	socks5 = true, socks = true, http = true, https = true,
}

local function valid_name(name)
	return type(name) == "string" and #name <= 64 and name:match("^[%w_.-]+$") ~= nil and not RESERVED[name]
end

local function protocol(value)
	return tostring(value or ""):match("^([%w+.-]+)://")
end

local function nested_sections(body)
	local parsed = config.parse(body)
	return parsed and parsed.sections or {}
end

local function subscription_catalog(body)
	local result, nested_by_name = {}, {}
	for _, section in ipairs(nested_sections(body)) do
		local values = config.key_values(config.section_body(body, section))
		if values.url and values.url ~= "" then
			nested_by_name[section.name] = true
			result[#result + 1] = {
				name = section.name,
				kind = "subscription",
				protocol = protocol(values.url) or "http",
				enabled = config.trim(values.enabled or "true"):lower() ~= "false",
				updateInterval = tonumber(values.update_interval) or 86400,
			}
		end
	end
	local flat = body
	local sections = nested_sections(body)
	for index = #sections, 1, -1 do
		local section = sections[index]
		flat = flat:sub(1, section.start - 1) .. flat:sub(section.finish + 1)
	end
	for _, entry in ipairs(config.named_entries(flat)) do
		if not nested_by_name[entry.name] then
			result[#result + 1] = {
				name = entry.name, kind = "subscription", protocol = protocol(entry.value) or "http",
				enabled = true, updateInterval = 86400,
			}
		end
	end
	return result
end

function M.catalog(content)
	local nodes, subscriptions = {}, {}
	local node_section = config.section(content, "node")
	if node_section then
		for _, entry in ipairs(config.named_entries(config.section_body(content, node_section))) do
			nodes[#nodes + 1] = { name = entry.name, kind = "node", protocol = protocol(entry.value) or "unknown" }
		end
	end
	local subscription_section = config.section(content, "subscription")
	if subscription_section then subscriptions = subscription_catalog(config.section_body(content, subscription_section)) end
	table.sort(nodes, function(a, b) return a.name < b.name end)
	table.sort(subscriptions, function(a, b) return a.name < b.name end)
	return { nodes = nodes, subscriptions = subscriptions }
end

local function url_encode(value)
	return tostring(value or ""):gsub("([^%w_.~-])", function(char)
		return string.format("%%%02X", string.byte(char))
	end)
end

local function clash_api(content)
	local experimental = config.section(content, "experimental")
	if not experimental then return nil end
	local body = config.section_body(content, experimental)
	local parsed = config.parse(body)
	if not parsed then return nil end
	for _, section in ipairs(parsed.sections) do
		if section.name == "clash_api" then
			local values = config.key_values(config.section_body(body, section))
			local controller = config.trim(values.external_controller or "")
			local port = controller:match(":(%d+)$")
			if not port then return nil end
			local secret = config.trim(values.secret or "")
			local headers = secret ~= "" and " --header=" .. config.shell_quote("Authorization: Bearer " .. secret) or ""
			return "http://127.0.0.1:" .. port, headers
		end
	end
	return nil
end

local function runtime_request(url, headers)
	local sys = require "luci.sys"
	local command = "wget -q -T 2 -t 1" .. (headers or "") .. " -O - " .. config.shell_quote(url) .. " 2>/dev/null"
	local output = sys.exec(command) or ""
	return jsonc.parse(output)
end

local function runtime_delay_request(url, headers)
	local sys = require "luci.sys"
	local command = "curl -sS -m 12" .. (headers or "") .. " -o - " .. config.shell_quote(url) .. " 2>/dev/null"
	local output = sys.exec(command) or ""
	return jsonc.parse(output)
end

function M.refresh_subscription(content, name)
	local sys = require "luci.sys"
	local endpoint, headers = clash_api(content)
	if not endpoint then
		-- Subscription fetching is a core service concern.  When the optional
		-- Clash control plane is disabled, restart/start Honk so its native
		-- startup fetch refreshes all configured subscriptions.
		local init = os.getenv("HONK_INIT_PATH") or "/etc/init.d/honk"
		local running = sys.call("pidof honk-core >/dev/null 2>&1") == 0
		local action = running and "restart" or "start"
		local code = sys.call(config.shell_quote(init) .. " " .. action .. " >/dev/null 2>&1")
		if code ~= 0 then return false, "Honk service refresh failed" end
		return true, nil
	end
	local url = endpoint .. "/subscriptions/" .. url_encode(name) .. "/refresh"
	local command = "wget -q -T 3 -t 1 --post-data=''" .. (headers or "") .. " -O /dev/null " .. config.shell_quote(url) .. " 2>/dev/null"
	local code = sys.call(command)
	return code == 0, code == 0 and nil or "Honk subscription endpoint is unavailable"
end

local function protocol_name(value)
	local raw = tostring(value or "unknown"):lower()
	local aliases = {
		shadowsocks = "ss", vmess = "vmess", vless = "vless", trojan = "trojan",
		hysteria2 = "hysteria2", tuic = "tuic", juicity = "juicity", anytls = "anytls",
		socks5 = "socks5", http = "http",
	}
	return aliases[raw] or raw
end

local function configured_groups(content)
	local result = {}
	local section = config.section(content, "group")
	if not section then return result end
	local body = config.section_body(content, section)
	local parsed = config.parse(body)
	if not parsed then return result end
	for _, nested in ipairs(parsed.sections) do result[nested.name] = true end
	return result
end

-- Honk's native `/proxies` endpoint contains static and subscription nodes
-- after the runtime merge. Groups expose an `all` array, so they can be
-- excluded without guessing subscription ownership (which the native API
-- intentionally does not expose).
function M.runtime_catalog(content)
	local catalog = M.catalog(content)
	if #catalog.subscriptions == 0 then return { nodes = {}, available = false, configured = false } end
	local endpoint, headers = clash_api(content)
	if not endpoint then return { nodes = {}, available = false, configured = false } end
	local ownership = {}
	local subscription_state = runtime_request(endpoint .. "/subscriptions", headers)
	if type(subscription_state) == "table" and type(subscription_state.subscriptions) == "table" then
		for _, subscription in pairs(subscription_state.subscriptions) do
			if type(subscription) == "table" and type(subscription.name) == "string" and type(subscription.nodes) == "table" then
				for _, item in pairs(subscription.nodes) do
					if type(item) == "table" and type(item.name) == "string" and item.name ~= "" then
						ownership[item.name] = subscription.name
					end
				end
			end
		end
	end
	local response = runtime_request(endpoint .. "/proxies", headers)
	if type(response) ~= "table" or type(response.proxies) ~= "table" then return { nodes = {}, available = false, configured = true } end
	local excluded = {}
	for _, item in ipairs(catalog.nodes) do excluded[item.name] = true end
	for name in pairs(configured_groups(content)) do excluded[name] = true end
	local nodes, seen = {}, {}
	for name, item in pairs(response.proxies) do
		if type(name) == "string" and name ~= "GLOBAL" and name ~= "Proxy" and name ~= "direct" and name ~= "block"
			and not excluded[name] and type(item) == "table" and type(item.all) ~= "table" and not seen[name] then
			seen[name] = true
			nodes[#nodes + 1] = { name = name, subscription = ownership[name] or "runtime", protocol = protocol_name(item.type) }
		end
	end
	table.sort(nodes, function(a, b) return a.name < b.name end)
	return { nodes = nodes, available = true, configured = true }
end

local function catalog_has_node(content, name)
	for _, item in ipairs(M.catalog(content).nodes or {}) do
		if item.name == name then return true end
	end
	for _, item in ipairs(M.runtime_catalog(content).nodes or {}) do
		if item.name == name then return true end
	end
	return false
end

function M.delay(content, name)
	if type(name) ~= "string" or name == "" then return nil, "NODE_MISSING" end
	if not catalog_has_node(content, name) then return nil, "NODE_MISSING:" .. name end
	local endpoint, headers = clash_api(content)
	if not endpoint then return nil, "CLASH_API_UNAVAILABLE" end
	local target = M.DELAY_URL
	local url = endpoint .. "/proxies/" .. url_encode(name) .. "/delay?url=" .. url_encode(target) .. "&timeout=" .. tostring(M.DELAY_TIMEOUT)
	local response = runtime_delay_request(url, headers)
	if type(response) ~= "table" then return nil, "DELAY_API_INVALID" end
	local delay = tonumber(response.delay)
	if delay and delay >= 0 then
		return { name = name, delay = delay, target = target }, nil
	end
	return nil, config.trim(response.message or "NODE_DELAY_FAILED")
end

function M.proxy_delay(content, group_name, target)
	if type(group_name) ~= "string" or group_name == "" or type(target) ~= "string" or target == "" then
		return nil, "NODE_DELAY_FAILED"
	end
	local endpoint, headers = clash_api(content)
	if not endpoint then return nil, "CLASH_API_UNAVAILABLE" end
	local url = endpoint .. "/proxies/" .. url_encode(group_name) .. "/delay?url=" .. url_encode(target) .. "&timeout=" .. tostring(M.DELAY_TIMEOUT)
	local response = runtime_delay_request(url, headers)
	if type(response) ~= "table" then return nil, "DELAY_API_INVALID" end
	local delay = tonumber(response.delay)
	if delay and delay >= 0 then
		return { name = group_name, delay = delay, target = target }, nil
	end
	return nil, config.trim(response.message or "NODE_DELAY_FAILED")
end

function M.set_group_selection(content, group_name, node_name)
	if type(group_name) ~= "string" or group_name == "" or type(node_name) ~= "string" or node_name == "" then
		return false, "NODE_MISSING"
	end
	local endpoint, headers = clash_api(content)
	if not endpoint then return false, "CLASH_API_UNAVAILABLE" end
	local sys = require "luci.sys"
	local body = jsonc.stringify({ name = node_name })
	local url = endpoint .. "/proxies/" .. url_encode(group_name)
	local command = "curl -sS -m 5 -o /dev/null -w '%{http_code}' -X PUT" .. (headers or "") ..
		" -H " .. config.shell_quote("Content-Type: application/json") ..
		" --data-raw " .. config.shell_quote(body) .. " " .. config.shell_quote(url) .. " 2>/dev/null"
	local status = tonumber(sys.exec(command) or "")
	return status == 200 or status == 204, status and ("HTTP_" .. tostring(status)) or "CLASH_API_UNAVAILABLE"
end

local function names_set(list)
	local result = {}
	for _, item in ipairs(list or {}) do
		local name = type(item) == "table" and item.name or item
		if type(name) == "string" and name ~= "" then result[name] = true end
	end
	return result
end

function M.select(content, input)
	input = type(input) == "table" and input or {}
	local catalog = M.catalog(content)
	local available_nodes, available_subscriptions = names_set(catalog.nodes), names_set(catalog.subscriptions)
	local available_runtime = names_set(input.runtimeNodeNames)
	local selected_nodes, selected_subscriptions, seen = {}, {}, {}
	if type(input.nodeNames) ~= "table" or type(input.subscriptionNames) ~= "table" then
		return nil, "PROXY_SOURCE_INVALID"
	end
	if #input.nodeNames + #input.subscriptionNames > 32 then return nil, "PROXY_SOURCE_LIMIT" end
	for _, name in ipairs(input.nodeNames) do
		if type(name) ~= "string" or (not available_nodes[name] and not available_runtime[name]) then return nil, "NODE_MISSING:" .. tostring(name) end
		if not seen["node:" .. name] then selected_nodes[#selected_nodes + 1] = name; seen["node:" .. name] = true end
	end
	for _, name in ipairs(input.subscriptionNames) do
		if type(name) ~= "string" or not available_subscriptions[name] then return nil, "SUBSCRIPTION_MISSING:" .. tostring(name) end
		if not seen["subscription:" .. name] then selected_subscriptions[#selected_subscriptions + 1] = name; seen["subscription:" .. name] = true end
	end
	if #selected_nodes + #selected_subscriptions == 0 then return nil, "PROXY_SOURCE_REQUIRED" end
	return { nodes = selected_nodes, subscriptions = selected_subscriptions }, nil
end

function M.filters(selected)
	local lines = {}
	for _, name in ipairs(selected.nodes or {}) do
		lines[#lines + 1] = "\t\tfilter: name(" .. config.dae_quote(name) .. ")"
	end
	for _, name in ipairs(selected.subscriptions or {}) do
		lines[#lines + 1] = "\t\tfilter: subscription(" .. config.dae_quote(name) .. ")"
	end
	return lines
end

local function append_body(body, value)
	local clean = tostring(body or ""):gsub("%s*$", "")
	if clean == "" then return "\n" .. value .. "\n" end
	return clean .. "\n" .. value .. "\n"
end

local function remove_flat_line(body, name)
	local output, removed = {}, false
	for line in (tostring(body or "") .. "\n"):gmatch("([^\n]*)\n") do
		local key = line:match("^%s*([%w_.-]+)%s*:")
		if key == name then removed = true else output[#output + 1] = line end
	end
	return table.concat(output, "\n"), removed
end

local function mutate_node(content, action, input)
	local section = config.section(content, "node")
	local body = section and config.section_body(content, section) or ""
	local removed
	if action == "add-node" then
		local scheme = protocol(input.url)
		if not valid_name(input.name) then return nil, "NODE_NAME_INVALID" end
		if not scheme or not NODE_SCHEMES[scheme:lower()] or #input.url > 4096 then return nil, "NODE_URL_INVALID" end
		for _, entry in ipairs(config.named_entries(body)) do if entry.name == input.name then return nil, "NODE_DUPLICATE" end end
		body = append_body(body, "\t" .. input.name .. ": " .. config.dae_quote(input.url))
	elseif action == "remove-node" then
		body, removed = remove_flat_line(body, input.name)
		if not removed then return nil, "NODE_MISSING" end
	else
		return nil, "NODE_ACTION_INVALID"
	end
	return config.replace_section(content, "node", "node {" .. body .. "}")
end

local function mutate_subscription(content, action, input)
	local section = config.section(content, "subscription")
	local body = section and config.section_body(content, section) or ""
	local catalog = subscription_catalog(body)
	if action == "add-subscription" then
		if not valid_name(input.name) then return nil, "SUBSCRIPTION_NAME_INVALID" end
		if type(input.url) ~= "string" or not input.url:match("^https?://[^%s]+$") or #input.url > 4096 then return nil, "SUBSCRIPTION_URL_INVALID" end
		for _, item in ipairs(catalog) do if item.name == input.name then return nil, "SUBSCRIPTION_DUPLICATE" end end
		local interval = math.floor(tonumber(input.updateInterval) or 86400)
		if interval < 0 or interval > 604800 then return nil, "SUBSCRIPTION_INTERVAL_INVALID" end
		local block = table.concat({
			"\t" .. input.name .. " {",
			"\t\turl: " .. config.dae_quote(input.url),
			"\t\tupdate_interval: " .. tostring(interval),
			"\t\tenabled: true",
			"\t}",
		}, "\n")
		body = append_body(body, block)
	elseif action == "remove-subscription" then
		local parsed = config.parse(body)
		local removed = false
		if parsed then
			for index = #parsed.sections, 1, -1 do
				local nested = parsed.sections[index]
				if nested.name == input.name then
					body = body:sub(1, nested.start - 1) .. body:sub(nested.finish + 1)
					removed = true
				end
			end
		end
		local next_body, flat_removed = remove_flat_line(body, input.name)
		body, removed = next_body, removed or flat_removed
		if not removed then return nil, "SUBSCRIPTION_MISSING" end
	else
		return nil, "SUBSCRIPTION_ACTION_INVALID"
	end
	return config.replace_section(content, "subscription", "subscription {" .. body .. "}")
end

function M.mutate(content, input)
	if type(input) ~= "table" or type(input.action) ~= "string" then return nil, "SOURCE_ACTION_INVALID" end
	if input.action == "add-node" or input.action == "remove-node" then return mutate_node(content, input.action, input) end
	if input.action == "add-subscription" or input.action == "remove-subscription" then return mutate_subscription(content, input.action, input) end
	return nil, "SOURCE_ACTION_INVALID"
end

return M
