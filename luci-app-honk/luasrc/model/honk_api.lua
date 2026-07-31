local fs = require "nixio.fs"
local nixio = require "nixio"
local sys = require "luci.sys"
local jsonc = require "luci.jsonc"

local M = {}
local CONFIG = "/etc/honk/config.dae"
local BACKUP = "/etc/honk/config.dae.last-good"
local RUN_DIR = "/var/run/honk"
local MAX_CONFIG = 1048576
local APP_DIR = "/www/luci-static/resources/honk/app"

local function shell_quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

local function read(path)
	return fs.readfile(path) or ""
end

local function trim(value)
	return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function unquote(value)
	value = trim(value)
	if (#value >= 2) and ((value:sub(1, 1) == "'" and value:sub(-1) == "'") or (value:sub(1, 1) == '"' and value:sub(-1) == '"')) then
		return value:sub(2, -2)
	end
	return value
end

local function dae_quote(value)
	return "'" .. tostring(value or ""):gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

local function decode_uri(value)
	value = (value or ""):gsub("+", " ")
	return value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
end

local function section_end(content, open)
	local depth, quote, escaped, comment = 0, nil, false, false
	for index = open, #content do
		local char = content:sub(index, index)
		if comment then
			if char == "\n" then comment = false end
		elseif quote then
			if escaped then escaped = false
			elseif char == "\\" then escaped = true
			elseif char == quote then quote = nil end
		elseif char == "#" then comment = true
		elseif char == "'" or char == '"' then quote = char
		elseif char == "{" then depth = depth + 1
		elseif char == "}" then
			depth = depth - 1
			if depth == 0 then return index end
		end
	end
	return nil
end

local function top_sections(content)
	local result, index = {}, 1
	while index <= #content do
		local start_name, end_name, name = content:find("([%a_][%w_-]*)%s*{", index)
		if not start_name then break end
		local open = content:find("{", end_name - 1, true)
		local close = open and section_end(content, open)
		if not close then break end
		result[#result + 1] = { name = name, body = content:sub(open + 1, close - 1), start = start_name, finish = close }
		index = close + 1
	end
	return result
end

local function find_section(content, name)
	for _, section in ipairs(top_sections(content or "")) do
		if section.name == name then return section end
	end
	return nil
end

local function set_body_key(body, key, value, indent, closing_indent)
	local wrapped = "\n" .. (body or "")
	local count
	wrapped, count = wrapped:gsub("\n([ \t]*)" .. key .. "([ \t]*:[ \t]*)[^\n]*", function(spaces, separator)
		return "\n" .. spaces .. key .. separator .. value
	end, 1)
	if count > 0 then return wrapped:sub(2) end

	local trailing = (body or ""):match("(%s*)$") or ""
	local head = (body or ""):sub(1, #(body or "") - #trailing)
	if trailing == "" then trailing = "\n" .. closing_indent end
	if head == "" then return "\n" .. indent .. key .. ": " .. value .. trailing end
	return head .. "\n" .. indent .. key .. ": " .. value .. trailing
end

local function render_section(name, values, indent, value_indent)
	local lines = { indent .. name .. " {" }
	for _, assignment in ipairs(values) do
		lines[#lines + 1] = value_indent .. assignment[1] .. ": " .. assignment[2]
	end
	lines[#lines + 1] = indent .. "}"
	return table.concat(lines, "\n")
end

local function set_nested_section(content, outer_name, nested_name, values)
	local outer = find_section(content, outer_name)
	if not outer then
		local prefix = (content or ""):gsub("%s*$", "")
		local nested = render_section(nested_name, values, "\t", "\t\t")
		local block = outer_name .. " {\n" .. nested .. "\n}"
		return prefix .. (prefix ~= "" and "\n\n" or "") .. block .. "\n"
	end

	local nested = find_section(outer.body, nested_name)
	local outer_body
	if nested then
		local nested_body = nested.body
		for _, assignment in ipairs(values) do
			nested_body = set_body_key(nested_body, assignment[1], assignment[2], "\t\t", "\t")
		end
		outer_body = outer.body:sub(1, nested.start - 1)
			.. nested_name .. " {" .. nested_body .. "}"
			.. outer.body:sub(nested.finish + 1)
	else
		local trailing = outer.body:match("(%s*)$") or ""
		local head = outer.body:sub(1, #outer.body - #trailing)
		local block = render_section(nested_name, values, "\t", "\t\t")
		if trailing == "" then trailing = "\n" end
		outer_body = head .. (head ~= "" and "\n\n" or "\n") .. block .. trailing
	end

	return content:sub(1, outer.start - 1)
		.. outer_name .. " {" .. outer_body .. "}"
		.. content:sub(outer.finish + 1)
end

local function strip_line_comment(line)
	local quote, escaped = nil, false
	for index = 1, #line do
		local char = line:sub(index, index)
		if quote then
			if escaped then escaped = false
			elseif char == "\\" then escaped = true
			elseif char == quote then quote = nil end
		elseif char == "'" or char == '"' then quote = char
		elseif char == "#" then return line:sub(1, index - 1) end
		end
	return line
end

local function key_values(body)
	local result = {}
	for line in (body or ""):gmatch("[^\n]+") do
		line = strip_line_comment(line)
		local key, value = line:match("^%s*([%w_-]+)%s*:%s*(.-)%s*$")
		if key and value then result[key] = unquote(value) end
	end
	return result
end

local function named_entries(body)
	local result = {}
	for line in (body or ""):gmatch("[^\n]+") do
		line = strip_line_comment(line)
		local key, value = line:match("^%s*([%w_.-]+)%s*:%s*(.-)%s*$")
		if key and value then
			result[#result + 1] = { name = key, value = unquote(value) }
		end
	end
	return result
end

local function parse_dns_upstream(entry)
	local raw = trim(entry.value)
	local uri, outbound = raw:match("^(.-)%s*%-%>%s*([%w_.-]+)%s*$")
	uri = uri or raw
	local scheme, rest = uri:match("^([%w+.-]+)://(.+)$")
	if not scheme then scheme, rest = "udp", uri end
	scheme = scheme:lower()
	local without_query, query = rest:match("^([^?]*)%??(.*)$")
	without_query = without_query or rest
	local authority, path = without_query:match("^([^/]+)(/.*)$")
	authority = authority or without_query
	path = path or ""
	local host, port = authority:match("^%[([^%]]+)%]:(%d+)$")
	if not host then host, port = authority:match("^([^:]+):(%d+)$") end
	if not host then host = authority end
	local defaults = { udp = 53, tcp = 53, ["tcp+udp"] = 53, tls = 853, https = 443, h3 = 443, quic = 853 }
	local params = {}
	for pair in (query or ""):gmatch("[^&]+") do
		local key, value = pair:match("^([^=]+)=?(.*)$")
		if key then params[decode_uri(key)] = decode_uri(value) end
	end
	return {
		name = entry.name,
		value = entry.value,
		protocol = scheme,
		host = decode_uri(host or ""),
		port = tonumber(port) or defaults[scheme] or 53,
		path = path ~= "" and path or nil,
		sni = params.tls_server_name or params.sni,
		outbound = outbound,
		query = params,
	}
end

local function parse_dns_routes(body)
	local routes = {
		requestRules = {}, requestFallback = "",
		responseRules = {}, responseFallback = "accept",
	}
	local routing = find_section(body or "", "routing")
	if not routing then return routes end
	local function read_rules(section, rules, fallback_key)
		if not section then return end
		for line in section.body:gmatch("[^\n]+") do
			local clean = trim(strip_line_comment(line))
			if clean ~= "" and clean:match("^fallback%s*:") then
				routes[fallback_key] = trim(clean:match("^fallback%s*:%s*(.-)%s*$"))
			elseif clean ~= "" and clean:find("->", 1, true) then
				rules[#rules + 1] = clean
			end
		end
	end
	local request = find_section(routing.body, "request")
	local response = find_section(routing.body, "response")
	read_rules(request, routes.requestRules, "requestFallback")
	read_rules(response, routes.responseRules, "responseFallback")
	return routes
end

local function parse_node_link(link)
	if type(link) ~= "string" then return nil, "share link must be a string" end
	link = trim(link)
	local scheme, rest = link:match("^([%w+.-]+)://(.+)$")
	if not scheme then return nil, "share link scheme is missing" end
	local without_fragment, fragment = rest:match("^([^#]*)#(.*)$")
	without_fragment = without_fragment or rest
	local authority, query = without_fragment:match("^([^?]*)%??(.*)$")
	local userinfo, hostport = authority:match("^(.+)@(.+)$")
	userinfo = userinfo or ""
	hostport = hostport or authority
	local host, port = hostport:match("^%[([^%]]+)%]:(%d+)$")
	if not host then host, port = hostport:match("^([^:]+):(%d+)$") end
	if not host then host = hostport end
	local username, password = userinfo:match("^([^:]+):(.+)$")
	username = decode_uri(username or userinfo)
	password = decode_uri(password or "")
	if scheme:lower() == "anytls" and password == "" and username ~= "" then password = username end
	local params = {}
	for pair in query:gmatch("[^&]+") do
		local key, value = pair:match("^([^=]+)=?(.*)$")
		if key then params[decode_uri(key)] = decode_uri(value) end
	end
	local secure = params.security == "tls" or params.security == "reality" or params.tls == "1" or scheme == "trojan" or scheme == "anytls"
	return {
		raw = link, name = decode_uri(fragment or "") ~= "" and decode_uri(fragment) or host,
		protocol = scheme:lower(), host = decode_uri(host), port = tonumber(port) or 443,
		username = username ~= "" and username or nil, password = password ~= "" and password or nil,
		tls = secure, sni = params.sni or params.peer, network = params.type or params.network or "tcp",
		insecure = params.insecure == "1" or params.allowInsecure == "1" or params.allow_insecure == "1",
		query = params,
	}, nil
end

local function hash_file(path)
	local sha = io.popen("sha256sum " .. string.format("%q", path) .. " 2>/dev/null")
	if not sha then return "" end
	local line = sha:read("*l") or ""
	sha:close()
	return trim(line:match("^([0-9a-f]+)"))
end

local function revision(content)
	local temp = "/tmp/honk-revision-" .. tostring(nixio.getpid and nixio.getpid() or 1)
	if not fs.writefile(temp, content or "") then return "" end
	local value = hash_file(temp)
	fs.remove(temp)
	return value
end

local function current_revision()
	return hash_file(CONFIG)
end

local function error_response(code, message, status)
	return { ok = false, error = { code = code, message = message } }, status or 400
end

local function lock_path()
	return RUN_DIR .. "/config.lock"
end

local function with_lock(callback)
	fs.mkdir(RUN_DIR)
	local lock = nixio.open(lock_path(), "w", 600)
	if not lock then return error_response("LOCK_FAILED", "configuration lock is unavailable", 503) end
	local ok = lock:lock("lock")
	if not ok then lock:close(); return error_response("LOCK_FAILED", "configuration lock is unavailable", 503) end
	local called, result, status = pcall(callback)
	lock:close()
	if not called then return error_response("INTERNAL_ERROR", "configuration operation failed", 500) end
	return result, status
end

local function validate_file(path)
	local command = "/usr/bin/honk-tool validate --config " .. string.format("%q", path) .. " --json 2>&1; printf '\\n__HONK_EXIT:%s' \"$?\""
	local pipe = io.popen(command)
	if not pipe then return false, "unable to run configuration validator" end
	local output = pipe:read("*a") or ""
	pipe:close()
	local code = tonumber(output:match("__HONK_EXIT:(%d+)%s*$"))
	local detail = output:gsub("%s*__HONK_EXIT:%d+%s*$", "")
	return code == 0, trim(detail)
end

local function write_atomic(content)
	local pid = tostring(nixio.getpid and nixio.getpid() or math.random(100000, 999999))
	local temp = CONFIG .. ".tmp." .. pid
	if not fs.writefile(temp, content) then return false, "unable to write temporary configuration" end
	fs.chmod(temp, 600)
	if not fs.rename(temp, CONFIG) then fs.remove(temp); return false, "unable to replace configuration" end
	return true
end

function M.state()
	local content = read(CONFIG)
	local running = sys.call("pidof honk-core >/dev/null 2>&1") == 0
	local active = trim(read(RUN_DIR .. "/active-revision"))
	if active == "" and running then active = revision(content) end
	return {
		ok = true,
		running = running,
		config = content,
		diskRevision = revision(content),
		activeRevision = active,
		dirty = active ~= "" and active ~= revision(content),
	}
end

function M.validate(content)
	if type(content) ~= "string" then return error_response("INVALID_CONFIG", "config must be a string") end
	if #content > MAX_CONFIG then return error_response("CONFIG_TOO_LARGE", "configuration exceeds 1 MiB", 413) end
	local temp = "/tmp/honk-validate-" .. tostring(nixio.getpid and nixio.getpid() or 1)
	fs.writefile(temp, content); fs.chmod(temp, 600)
	local ok, detail = validate_file(temp)
	fs.remove(temp)
	if not ok then return error_response("INVALID_CONFIG", detail ~= "" and detail or "configuration validation failed") end
	return { ok = true, valid = true }
end

function M.save(content, expected, apply)
	if type(content) ~= "string" then return error_response("INVALID_CONFIG", "config must be a string") end
	if #content > MAX_CONFIG then return error_response("CONFIG_TOO_LARGE", "configuration exceeds 1 MiB", 413) end
	return with_lock(function()
		local current = current_revision()
		if type(expected) ~= "string" or expected == "" then
			return error_response("REVISION_REQUIRED", "configuration revision is required", 400)
		end
		if expected ~= current then
			return error_response("REVISION_CONFLICT", "configuration changed; reload before saving", 409)
		end
		local temp = CONFIG .. ".candidate." .. tostring(nixio.getpid and nixio.getpid() or 1)
		fs.writefile(temp, content); fs.chmod(temp, 600)
		local valid, detail = validate_file(temp)
		if not valid then fs.remove(temp); return error_response("INVALID_CONFIG", detail ~= "" and detail or "configuration validation failed") end
		fs.copy(CONFIG, BACKUP)
		local replaced, replace_error = write_atomic(content)
		fs.remove(temp)
		if not replaced then return error_response("WRITE_FAILED", replace_error, 500) end
		local disk = revision(content)
		if not apply then return { ok = true, saved = true, diskRevision = disk, activeRevision = trim(read(RUN_DIR .. "/active-revision")) } end
		local was_running = sys.call("pidof honk-core >/dev/null 2>&1") == 0
		if not was_running then
			return { ok = true, saved = true, applied = false, diskRevision = disk, activeRevision = trim(read(RUN_DIR .. "/active-revision")) }
		end
		local restart_code = sys.call("/etc/init.d/honk restart >/dev/null 2>&1")
		local healthy = restart_code == 0 and sys.call("pidof honk-core >/dev/null 2>&1") == 0
		if healthy then
			fs.mkdir(RUN_DIR); fs.writefile(RUN_DIR .. "/active-revision", disk); fs.chmod(RUN_DIR .. "/active-revision", 600)
			return { ok = true, applied = true, diskRevision = disk, activeRevision = disk }
		end
		if fs.access(BACKUP) then
			fs.copy(BACKUP, CONFIG)
			sys.call("/etc/init.d/honk restart >/dev/null 2>&1")
		end
		return error_response("ROLLBACK", "service restart failed; last working configuration was restored", 500)
	end)
end

function M.service(action)
	if not ({ start = true, stop = true, restart = true, reload = true })[action] then return error_response("INVALID_ACTION", "unsupported service action") end
	local code = sys.call("/etc/init.d/honk " .. action .. " >/dev/null 2>&1")
	if code ~= 0 then return error_response("SERVICE_FAILED", "service action failed", 500) end
	return { ok = true, action = action, state = M.state() }
end

function M.logs()
	local output = sys.exec("tail -n 200 /tmp/honk/honk.log 2>/dev/null")
	output = (output or ""):gsub("([%w+%.%-]+://)[^@%s]+@", "%1***@")
	output = output:gsub("([Pp]assword%s*[:=]%s*)[^%s,]+", "%1***")
	output = output:gsub("([Ss]ecret%s*[:=]%s*)[^%s,]+", "%1***")
	output = output:gsub("([Tt]oken%s*[:=]%s*)[^%s,]+", "%1***")
	return { ok = true, lines = output or "" }
end

function M.traffic()
	local output = sys.exec("/usr/bin/honk-tool bpf stats --pin-root /sys/fs/bpf/honk --json --sample-ms 1000 2>/dev/null")
	local parsed = output ~= "" and jsonc.parse(output) or nil
	if type(parsed) == "table" then return parsed end
	return { ok = false, available = false, error = "traffic statistics unavailable" }
end

local function clash_api_settings(content)
	for _, section in ipairs(top_sections(content or "")) do
		if section.name == "experimental" then
			for _, nested in ipairs(top_sections(section.body)) do
				if nested.name == "clash_api" then return key_values(nested.body) end
			end
		end
	end
	return {}
end

local function experimental_section_settings(content, name)
	local experimental = find_section(content or "", "experimental")
	if not experimental then return {}, false end
	local nested = find_section(experimental.body, name)
	if not nested then return {}, false end
	return key_values(nested.body), true
end

local function controller_parts(value)
	value = trim(value):gsub("^https?://", "")
	value = value:match("^([^/]+)") or value
	local host, port = value:match("^%[([^%]]+)%]:(%d+)$")
	if not host then host, port = value:match("^([^:]+):(%d+)$") end
	return trim(host), tonumber(port)
end

local function controller_is_browser_accessible(host, port)
	if not host or host == "" or not port or port < 1 or port > 65535 then return false end
	host = host:lower()
	return host ~= "127.0.0.1" and host ~= "localhost" and host ~= "::1"
end

function M.dashboard()
	local content = read(CONFIG)
	local clash = clash_api_settings(content)
	local configured_model = M.model(content).model
	local cache, cache_exists = experimental_section_settings(content, "cache_file")
	local host, port = controller_parts(clash.external_controller or "")
	local controller_ready = controller_is_browser_accessible(host, port)
	local ui_ready = trim(clash.external_ui or "") == APP_DIR
	local secret_ready = trim(clash.secret or "") ~= ""
	local cache_ready = cache_exists and trim(cache.enabled or ""):lower() == "true"
	local cache_path_ready = cache_ready and trim(cache.path or "") ~= "" and trim(cache.path or "") ~= "cache.db"
	local assets_ready = fs.access(APP_DIR .. "/index.html") and true or false
	local needs_migration = not controller_ready or not ui_ready or not secret_ready or not cache_ready or not cache_path_ready

	return {
		ok = true,
		ready = not needs_migration and assets_ready,
		needsMigration = needs_migration,
		running = sys.call("pidof honk-core >/dev/null 2>&1") == 0,
		controllerPort = port or 9090,
		secret = clash.secret or "",
		configuredNodeCount = #configured_model.nodes,
		externalUi = clash.external_ui or "",
		assetsReady = assets_ready,
	}
end

local function random_secret()
	local source = nixio.open("/dev/urandom", "r")
	if not source then return nil end
	local bytes = source:read(32)
	source:close()
	if type(bytes) ~= "string" or #bytes ~= 32 then return nil end
	local encoded = {}
	for index = 1, #bytes do encoded[#encoded + 1] = string.format("%02x", bytes:byte(index)) end
	return table.concat(encoded)
end

function M.dashboard_prepare()
	local current = read(CONFIG)
	local clash = clash_api_settings(current)
	local cache, cache_exists = experimental_section_settings(current, "cache_file")
	local host, port = controller_parts(clash.external_controller or "")
	port = port or 9090
	local controller = trim(clash.external_controller or "")
	if not controller_is_browser_accessible(host, port) then controller = "0.0.0.0:" .. tostring(port) end
	local secret = trim(clash.secret or "")
	if secret == "" then
		secret = random_secret()
		if not secret then return error_response("SECRET_FAILED", "failed to generate dashboard secret", 500) end
	end

	local updated = set_nested_section(current, "experimental", "clash_api", {
		{ "external_controller", dae_quote(controller) },
		{ "external_ui", dae_quote(APP_DIR) },
		{ "secret", dae_quote(secret) },
	})
	local cache_values = { { "enabled", "true" } }
	local cache_path = trim(cache.path or "")
	if cache_path == "" or cache_path == "cache.db" then
		cache_values[#cache_values + 1] = { "path", dae_quote("/etc/honk/cache.db") }
	end
	if trim(cache.cache_id or "") == "" then
		cache_values[#cache_values + 1] = { "cache_id", dae_quote("openwrt") }
	end
	if not cache_exists then
		cache_values[#cache_values + 1] = { "store_fakeip", "false" }
		cache_values[#cache_values + 1] = { "store_dns", "false" }
	end
	updated = set_nested_section(updated, "experimental", "cache_file", cache_values)

	if updated ~= current then
		local running = sys.call("pidof honk-core >/dev/null 2>&1") == 0
		local result, status = M.save(updated, current_revision(), running)
		if not result or not result.ok then return result, status end
	end
	local dashboard = M.dashboard()
	dashboard.migrated = updated ~= current
	return dashboard
end

function M.runtime_nodes()
	local settings = clash_api_settings(read(CONFIG))
	local controller = trim(settings.external_controller or "")
	if controller == "" then return { ok = true, available = false, nodes = {}, error = "Clash API is disabled" } end
	if not controller:match("^https?://") then controller = "http://" .. controller end
	controller = controller:gsub("/$", "")
	local command = "curl -fsS --max-time 3 " .. shell_quote(controller .. "/proxies")
	if trim(settings.secret or "") ~= "" then
		command = command .. " -H " .. shell_quote("Authorization: Bearer " .. settings.secret)
	end
	command = command .. " 2>/dev/null"
	local decoded = jsonc.parse(sys.exec(command) or "")
	local proxies = type(decoded) == "table" and decoded.proxies or nil
	if type(proxies) ~= "table" then
		return { ok = true, available = false, nodes = {}, error = "Clash API is not responding" }
	end
	local nodes = {}
	for name, info in pairs(proxies) do
		if type(info) == "table" and type(name) == "string" and name ~= "" then
			local kind = trim(info.type or "")
			local lower = kind:lower()
			if lower ~= "direct" and lower ~= "selector" and lower ~= "urltest" and lower ~= "loadbalance" and lower ~= "fallback" and lower ~= "relay" and name ~= "GLOBAL" then
				local history = type(info.history) == "table" and info.history[#info.history] or nil
				nodes[#nodes + 1] = {
					raw = "", name = name, protocol = lower ~= "" and lower or "proxy",
					host = "", port = 0, tls = false, network = "tcp",
					runtime = true, runtimeType = kind,
					latency = type(history) == "table" and tonumber(history.delay) or nil,
				}
			end
		end
	end
	table.sort(nodes, function(a, b) return a.name < b.name end)
	return { ok = true, available = true, nodes = nodes, fetchedAt = os.time() }
end

function M.model(content)
	content = type(content) == "string" and content or read(CONFIG)
	local sections, model = top_sections(content), {
		global = {}, nodes = {}, groups = {}, subscriptions = {}, routing = { rules = {}, fallback = "direct" },
		dns = {
			raw = "", upstreams = {}, requestRules = {}, requestFallback = "",
			responseRules = {}, responseFallback = "accept",
		}, experimental = { raw = "" },
		rawConfig = content,
	}
	for _, section in ipairs(sections) do
		if section.name == "global" then
			model.global = key_values(section.body)
		elseif section.name == "node" then
			for _, entry in ipairs(named_entries(section.body)) do
				local parsed = parse_node_link(entry.value)
				if parsed then parsed.name = entry.name ~= "" and entry.name or parsed.name; parsed.id = entry.name; model.nodes[#model.nodes + 1] = parsed end
			end
		elseif section.name == "subscription" then
			-- Old configurations use `name: url`, while the node page writes nested
			-- blocks with their own `url`, `enabled`, and `update_interval` fields.
			-- Remove the nested blocks before reading legacy flat entries.
			local flat_body = section.body
			local nested_sections = top_sections(section.body)
			for index = #nested_sections, 1, -1 do
				local nested = nested_sections[index]
				flat_body = flat_body:sub(1, nested.start - 1) .. flat_body:sub(nested.finish + 1)
			end
			for _, entry in ipairs(named_entries(flat_body)) do
				model.subscriptions[#model.subscriptions + 1] = { name = entry.name, url = entry.value, updateInterval = 86400, enabled = true }
			end
			for _, nested in ipairs(nested_sections) do
				local values = key_values(nested.body)
				if values.url and values.url ~= "" then
					model.subscriptions[#model.subscriptions + 1] = {
						name = nested.name,
						url = values.url,
						updateInterval = tonumber(values.update_interval) or 86400,
						enabled = trim(values.enabled or "true"):lower() ~= "false",
					}
				end
			end
		elseif section.name == "group" then
			for _, nested in ipairs(top_sections(section.body)) do
				local values = key_values(nested.body)
				local filters = {}
				for line in nested.body:gmatch("[^\n]+") do
					local filter = line:match("^%s*filter%s*:%s*(.-)%s*$")
					if filter and filter ~= "" then filters[#filters + 1] = filter end
				end
				model.groups[#model.groups + 1] = {
					name = nested.name,
					policy = values.policy or "",
					final = values.final or "",
					default = values.default or "",
					filter = table.concat(filters, " && "),
					raw = nested.body,
				}
			end
		elseif section.name == "routing" then
			for line in section.body:gmatch("[^\n]+") do
				local clean = trim(line:gsub("#.*$", ""))
				if clean ~= "" and clean:find("->", 1, true) then model.routing.rules[#model.routing.rules + 1] = clean
				elseif clean:match("^fallback%s*:") then model.routing.fallback = trim(clean:match("^fallback%s*:%s*(.-)%s*$")) end
			end
		elseif section.name == "dns" then
			model.dns.raw = section.body
			for _, nested in ipairs(top_sections(section.body)) do
				if nested.name == "upstream" then
					for _, upstream in ipairs(named_entries(nested.body)) do model.dns.upstreams[#model.dns.upstreams + 1] = parse_dns_upstream(upstream) end
				end
			end
			local routes = parse_dns_routes(section.body)
			model.dns.requestRules = routes.requestRules
			model.dns.requestFallback = routes.requestFallback
			model.dns.responseRules = routes.responseRules
			model.dns.responseFallback = routes.responseFallback
		elseif section.name == "experimental" then model.experimental.raw = section.body end
	end
	return { ok = true, model = model }
end

local function line_diff(before, after)
	local old, new = {}, {}
	for line in (before or ""):gmatch("[^\n]*\n?") do if line ~= "" then old[#old + 1] = line end end
	for line in (after or ""):gmatch("[^\n]*\n?") do if line ~= "" then new[#new + 1] = line end end
	local additions, removals, lines = 0, 0, {}
	local max = math.max(#old, #new)
	for i = 1, max do
		if old[i] ~= new[i] then
			if old[i] then removals = removals + 1; lines[#lines + 1] = "- " .. old[i]:gsub("\n$", "") end
			if new[i] then additions = additions + 1; lines[#lines + 1] = "+ " .. new[i]:gsub("\n$", "") end
		end
	end
	return additions, removals, table.concat(lines, "\n")
end

function M.preview(content)
	if type(content) ~= "string" then return error_response("INVALID_CONFIG", "config must be a string") end
	if #content > MAX_CONFIG then return error_response("CONFIG_TOO_LARGE", "configuration exceeds 1 MiB", 413) end
	local temp = "/tmp/honk-preview-" .. tostring(nixio.getpid and nixio.getpid() or 1)
	fs.writefile(temp, content); fs.chmod(temp, 600)
	local valid, detail = validate_file(temp)
	fs.remove(temp)
	if not valid then return error_response("INVALID_CONFIG", detail ~= "" and detail or "configuration validation failed") end
	local current = read(CONFIG)
	local additions, removals, diff = line_diff(current, content)
	return { ok = true, valid = true, changed = current ~= content, additions = additions, removals = removals, diff = diff, beforeRevision = revision(current), afterRevision = revision(content) }
end

function M.parse_node(link)
	local node, err = parse_node_link(link)
	if not node then return error_response("INVALID_NODE", err or "invalid share link") end
	return { ok = true, node = node }
end

function M.test_node(link, options)
	local node, err = parse_node_link(link)
	if not node then return error_response("INVALID_NODE", err or "invalid share link") end
	options = type(options) == "table" and options or {}
	local timeout = math.min(math.max(tonumber(options.timeout) or 5, 1), 30)
	local temp = "/tmp/honk-node-test-" .. tostring(nixio.getpid and nixio.getpid() or 1)
	fs.writefile(temp, trim(link) .. "\n"); fs.chmod(temp, 600)
	local target = trim(options.target or "cp.cloudflare.com:443")
	local url = trim(options.url or "https://www.gstatic.com/generate_204")
	local command = "/usr/bin/honk-tool sub " .. shell_quote(temp) .. " --limit 1 --timeout " .. tostring(timeout) .. " --target " .. shell_quote(target) .. " --url " .. shell_quote(url) .. " 2>&1"
	local pipe = io.popen(command)
	local output = pipe and (pipe:read("*a") or "") or ""
	if pipe then pipe:close() end
	fs.remove(temp)
	local summary = output:match("== ([^\n]+)") or "test completed"
	output = output:gsub("([%w+%.%-]+://)[^@%s]+@", "%1***@")
	return { ok = true, node = node, passed = output:find("urltest%-ok 0") == nil and output:find("v4%-proxied 0") == nil, summary = summary, output = trim(output) }
end

return M
