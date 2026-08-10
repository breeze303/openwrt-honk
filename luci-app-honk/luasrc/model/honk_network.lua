local fs = require "nixio.fs"

local config = require "luci.model.config"

local M = {}

M.DEFAULT_BOOTSTRAP_RESOLVER = "udp://223.5.5.5:53"

M.DIAL_MODES = {
	ip = true,
	domain = true,
	["domain+"] = true,
	["domain++"] = true,
}

local function trim(value)
	return config.trim(value or "")
end

local function reason(list, code)
	for _, value in ipairs(list) do
		if value == code then return end
	end
	list[#list + 1] = code
end

local function device_kind(name, status)
	if status.bridge or name:match("^br%-") then return "bridge" end
	if name:find(".", 1, true) then return "vlan" end
	if status.type == "tunnel" or name:match("^ppp") or name:match("^tun") or name:match("^wg") then return "tunnel" end
	return "device"
end

local function addresses(item)
	local result = {}
	for _, address in ipairs(item["ipv4-address"] or {}) do
		result[#result + 1] = {
			family = "ipv4",
			address = trim(address.address),
			prefix = tonumber(address.mask) or 0,
		}
	end
	for _, address in ipairs(item["ipv6-address"] or {}) do
		result[#result + 1] = {
			family = "ipv6",
			address = trim(address.address),
			prefix = tonumber(address.mask) or 0,
		}
	end
	return result
end

local function default_routes(item)
	local result, best = {}, nil
	for _, route in ipairs(item.route or {}) do
		local target = trim(route.target or route.dest)
		if target == "0.0.0.0" or target == "::" or target == "0.0.0.0/0" or target == "::/0" then
			local entry = {
				family = target:find(":", 1, true) and "ipv6" or "ipv4",
				metric = tonumber(route.metric) or 0,
				gateway = trim(route.nexthop or route.gateway),
			}
			result[#result + 1] = entry
			if not best or entry.metric < best.metric then best = entry end
		end
	end
	return result, best
end

local function ubus_connection()
	local loaded, ubus = pcall(require, "ubus")
	if not loaded or not ubus then return nil, "UBUS_UNAVAILABLE" end
	local connection = ubus.connect()
	if not connection then return nil, "UBUS_UNAVAILABLE" end
	return connection
end

function M.discover()
	local connection, connection_error = ubus_connection()
	if not connection then
		return { ok = false, interfaces = {}, candidates = {}, recommended = {}, ambiguous = true, error = connection_error }
	end
	local dump = connection:call("network.interface", "dump", {}) or {}
	local interfaces = {}
	for _, item in ipairs(dump.interface or {}) do
		local logical = trim(item.interface or item.name)
		local l3 = trim(item.l3_device)
		local routes, best = default_routes(item)
		interfaces[#interfaces + 1] = {
			logicalName = logical,
			l3Device = l3,
			device = trim(item.device),
			addresses = addresses(item),
			defaultRoute = best,
			defaultRoutes = routes,
			selectedBy = logical == "lan" and "lan" or (best and "default-route" or "none"),
			safe = l3 ~= "",
			present = false,
			up = false,
			kind = "unknown",
			reasonCodes = l3 == "" and { "L3_DEVICE_MISSING" } or {},
		}
	end

	for _, item in ipairs(interfaces) do
		local status = item.l3Device ~= "" and connection:call("network.device", "status", { name = item.l3Device }) or {}
		status = status or {}
		item.present = status.present ~= false and (status.present == true or status.exists == true or item.l3Device ~= "")
		item.up = status.up ~= false
		item.parent = trim(status.parent)
		item.kind = device_kind(item.l3Device, status)
		if #item.defaultRoutes > 1 then reason(item.reasonCodes, "MULTIPLE_DEFAULT_ROUTES") end
		if not item.present then reason(item.reasonCodes, "DEVICE_MISSING") end
		if not item.up then reason(item.reasonCodes, "DEVICE_DOWN") end
		item.safe = item.safe and item.present and item.up
	end

	local lan, wan, wan_metric
	for _, item in ipairs(interfaces) do
		if item.logicalName == "lan" and item.safe and #item.addresses > 0 and not lan then lan = item end
		if item.defaultRoute and item.safe and (not wan_metric or item.defaultRoute.metric < wan_metric) then
			wan, wan_metric = item, item.defaultRoute.metric
		end
	end
	local candidates = {}
	for _, item in ipairs(interfaces) do
		if item.safe and item.l3Device ~= "" and item.l3Device ~= "lo" then candidates[#candidates + 1] = item end
	end
	local ambiguous = not lan or not wan or lan.l3Device == wan.l3Device
	return {
		ok = true,
		interfaces = interfaces,
		candidates = candidates,
		recommended = { lan = lan and lan.l3Device or nil, wan = wan and wan.l3Device or nil },
		ambiguous = ambiguous,
		reasonCodes = ambiguous and { "INTERFACE_AMBIGUOUS" } or {},
	}
end

function M.current(content)
	local global = config.section(content or config.read(), "global")
	local values = global and config.key_values(config.section_body(content or config.read(), global)) or {}
	return {
		lan = trim(values.lan_interface),
		wan = trim(values.wan_interface),
		dialMode = trim(values.dial_mode) ~= "" and trim(values.dial_mode) or "domain",
		logLevel = trim(values.log_level) ~= "" and trim(values.log_level):lower() or "info",
	}
end

local function replace_key(body, key, value)
	local wrapped = "\n" .. (body or "")
	local pattern = "\n([ \t]*)" .. key .. "([ \t]*:[ \t]*)[^\n]*"
	local found = false
	local updated, count = wrapped:gsub(pattern, function(spaces, separator)
		if found then return "\n" end
		found = true
		return "\n" .. spaces .. key .. separator .. config.dae_quote(value)
	end)
	if count > 0 then return updated:sub(2) end
	local trailing = (body or ""):match("(%s*)$") or ""
	local head = (body or ""):sub(1, #(body or "") - #trailing)
	return head .. "\n\t" .. key .. ": " .. config.dae_quote(value) .. trailing
end

function M.update_global(content, values)
	local global, section_error = config.section(content, "global")
	if section_error then return nil, section_error end
	if not global then
		local lines = {
			"global {",
			"\tbootstrap_resolver: " .. config.dae_quote(M.DEFAULT_BOOTSTRAP_RESOLVER),
			"\twan_interface: " .. config.dae_quote(values.wan),
			"\tlan_interface: " .. config.dae_quote(values.lan),
			"\tdial_mode: " .. config.dae_quote(values.dialMode),
		}
		if values.logLevel and values.logLevel ~= "" then lines[#lines + 1] = "\tlog_level: " .. config.dae_quote(values.logLevel) end
		lines[#lines + 1] = "}"
		return config.replace_section(content, "global", table.concat(lines, "\n"))
	end
	local body = config.section_body(content, global)
	body = config.ensure_key(body, "bootstrap_resolver", M.DEFAULT_BOOTSTRAP_RESOLVER)
	body = replace_key(body, "lan_interface", values.lan)
	body = replace_key(body, "wan_interface", values.wan)
	body = replace_key(body, "dial_mode", values.dialMode)
	if values.logLevel and values.logLevel ~= "" then body = replace_key(body, "log_level", values.logLevel) end
	local block = "global {" .. body .. "}"
	return content:sub(1, global.start - 1) .. block .. content:sub(global.finish + 1)
end

function M.validate_selection(discovery, lan, wan, dial_mode)
	lan, wan, dial_mode = trim(lan), trim(wan), trim(dial_mode)
	if lan == "" or wan == "" or lan == "auto" or wan == "auto" then return nil, "INTERFACE_AMBIGUOUS" end
	if not M.DIAL_MODES[dial_mode] then return nil, "DIAL_MODE_INVALID" end
	local found_lan, found_wan
	for _, item in ipairs(discovery.candidates or {}) do
		if item.safe and item.l3Device == lan then found_lan = item end
		if item.safe and item.l3Device == wan then found_wan = item end
	end
	if not found_lan or not found_wan then return nil, "INTERFACE_NOT_AVAILABLE" end
	if lan == wan then return nil, "INTERFACE_SAME" end
	return { lan = lan, wan = wan, dialMode = dial_mode, lanInfo = found_lan, wanInfo = found_wan }
end

function M.snapshot(content)
	local discovery = M.discover()
	local current = M.current(content)
	discovery.current = current
	discovery.revision = config.file_revision()
	return discovery
end

return M
