local fs = require "nixio.fs"
local nixio = require "nixio"
local sys = require "luci.sys"
local jsonc = require "luci.jsonc"

local M = {}
local CONFIG = os.getenv("HONK_CONFIG_PATH") or "/etc/honk/config.dae"
local BACKUP = os.getenv("HONK_BACKUP_PATH") or "/etc/honk/config.dae.last-good"
local RUN_DIR = os.getenv("HONK_RUN_DIR") or "/var/run/honk"
local MAX_CONFIG = 1048576
local APP_DIR = "/www/luci-static/resources/honk-legacy/app"
local HONK_TOOL = os.getenv("HONK_TOOL_PATH") or "/usr/bin/honk-tool"

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
	local command = shell_quote(HONK_TOOL) .. " validate --config " .. string.format("%q", path) .. " --json 2>&1; printf '\\n__HONK_EXIT:%s' \"$?\""
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

-- Quick Setup is deliberately kept below the existing model API.  It owns a
-- small, structured projection of dae; the advanced editor continues to own
-- every byte outside the marker/global/group/routing/dns sections.
local QUICK_MARKER = "# honk-quick-setup: v1"
local QUICK_COMPILER = "honk.quick.v1"
local QUICK_DIR = os.getenv("HONK_QUICK_DIR") or "/run/honk/quick"
local QUICK_JOURNAL = os.getenv("HONK_QUICK_JOURNAL") or "/var/lib/honk/quick-transaction.json"
local QUICK_SIDECAR = os.getenv("HONK_QUICK_SIDECAR") or "/var/lib/honk/quick-transaction.previous"
local QUICK_WORKER = os.getenv("HONK_QUICK_WORKER") or "/usr/libexec/honk/quick-transaction-worker"
local QUICK_PRESETS = { gfwlist = true, ["china-direct"] = true, global = true, direct = true }
local QUICK_SECTIONS = { global = true, node = true, subscription = true, group = true, routing = true, dns = true, experimental = true }

local function quick_nonce()
	local source = nixio.open("/dev/urandom", "r")
	local bytes = source and source:read(24) or nil
	if source then source:close() end
	if type(bytes) ~= "string" or #bytes < 16 then return string.format("%x-%x", os.time(), math.random(100000, 999999)) end
	local out = {}
	for index = 1, #bytes do out[#out + 1] = string.format("%02x", bytes:byte(index)) end
	return table.concat(out)
end

local function quick_redact(value)
	value = tostring(value or "")
	value = value:gsub("([%w+%.%-]+://)[^@%s]+@", "%1***@")
	value = value:gsub("([?&])([%w_]+)([=:])([^&#%s]+)", function(prefix, key, separator, secret)
		if key:lower() == "token" or key:lower() == "key" or key:lower() == "password" or key:lower() == "secret" or key:lower() == "auth" then
			return prefix .. key .. separator .. "***"
		end
		return prefix .. key .. separator .. secret
	end)
	value = value:gsub("([Pp]assword%s*:%s*)[^%s,]+", "%1***")
	value = value:gsub("([Tt]oken%s*:%s*)[^%s,]+", "%1***")
	value = value:gsub("([Ss]ecret%s*:%s*)[^%s,]+", "%1***")
	return value
end

local function quick_strict_close(content, open)
	local depth, quote, escaped, comment = 1, nil, false, false
	for index = open + 1, #content do
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

local function quick_partition(content)
	if type(content) ~= "string" then return nil, { "INVALID_CONFIG" } end
	local reasons, sections, index, length = {}, {}, 1, #content
	local first_line = content:match("^([^\r\n]*)") or ""
	local marker_at = content:find(QUICK_MARKER, 1, true)
	local marker = first_line == QUICK_MARKER
	if marker_at and not marker then reasons[#reasons + 1] = "MARKER_SPOOFED" end
	if not marker then reasons[#reasons + 1] = "MARKER_MISSING" end
	while index <= length do
		while index <= length do
			local char = content:sub(index, index)
			if char:match("%s") then index = index + 1
			elseif char == "#" then
				local newline = content:find("\n", index, true)
				index = newline and newline + 1 or length + 1
			else break end
		end
		if index > length then break end
		local name = content:sub(index):match("^([%a_][%w_-]*)")
		local start_name, finish_name
		if name then
			start_name, finish_name = index, index + #name - 1
		end
		if not name then
			reasons[#reasons + 1] = "UNSUPPORTED_TOKEN"
			break
		end
		local open = finish_name + 1
		while open <= length and content:sub(open, open):match("%s") do open = open + 1 end
		if content:sub(open, open) ~= "{" then
			reasons[#reasons + 1] = name == "include" and "INCLUDE_UNSUPPORTED" or "UNTERMINATED_SECTION"
			break
		end
		local close = quick_strict_close(content, open)
		if not close then reasons[#reasons + 1] = "UNTERMINATED_BRACE"; break end
		sections[#sections + 1] = { name = name, start = start_name, finish = close, open = open, close = close }
		if not QUICK_SECTIONS[name] then reasons[#reasons + 1] = "UNKNOWN_SECTION:" .. name end
		index = close + 1
	end
	local seen = {}
	for _, section in ipairs(sections) do
		if seen[section.name] and (section.name == "global" or section.name == "group" or section.name == "routing" or section.name == "dns" or section.name == "experimental") then
			reasons[#reasons + 1] = "DUPLICATE_SECTION:" .. section.name
		end
		seen[section.name] = true
	end
	for _, section in ipairs(sections) do
		if section.name == "global" then
			for key in content:sub(section.open + 1, section.close - 1):gmatch("[%s\n]([%a_][%w_-]*)%s*:") do
				if key ~= "lan_interface" and key ~= "wan_interface" then
					reasons[#reasons + 1] = "GLOBAL_FIELD_OWNERSHIP:" .. key
				end
			end
		elseif section.name == "group" and content:sub(section.open + 1, section.close - 1):match("[%s\n]quick%-proxy%s*{") then
			reasons[#reasons + 1] = "QUICK_GROUP_NAME_COLLISION"
		elseif section.name == "node" and content:sub(section.open + 1, section.close - 1):match("[%s\n]quick%-proxy%s*{") then
			reasons[#reasons + 1] = "QUICK_NODE_NAME_COLLISION"
		end
	end
	local matcher_count = 0
	for _ in content:gmatch("%-%>") do matcher_count = matcher_count + 1 end
	if matcher_count > 128 then reasons[#reasons + 1] = "MATCHSET_LIMIT" end
	local spans, cursor = {}, 1
	for _, section in ipairs(sections) do
		if cursor < section.start then spans[#spans + 1] = { start = cursor, finish = section.start - 1, kind = "trivia" } end
		spans[#spans + 1] = { start = section.start, finish = section.finish, kind = "section", name = section.name }
		cursor = section.finish + 1
	end
	if cursor <= length then spans[#spans + 1] = { start = cursor, finish = length, kind = "trivia" } end
	if #spans == 0 and length == 0 then spans[1] = { start = 1, finish = 0, kind = "trivia" } end
	return { marker = marker, sections = sections, spans = spans, advanced = #reasons > 0, reasons = reasons, sourceSha256 = revision(content), spanDigest = revision(jsonc.stringify(spans)) }, nil
end

local function quick_section_map(partition)
	local map = {}
	for _, section in ipairs(partition.sections or {}) do map[section.name] = section end
	return map
end

local function quick_section_body(content, section)
	return section and content:sub(section.open + 1, section.close - 1) or ""
end

local function quick_prepare_dir()
	if not fs.access(QUICK_DIR) and not fs.mkdir(QUICK_DIR) and not fs.access(QUICK_DIR) then return false end
	fs.chmod(QUICK_DIR, 700)
	return true
end

local function quick_preserved_digest(content, partition)
	local slices = {}
	for _, span in ipairs(partition.spans or {}) do
		if span.finish >= span.start then
			if span.kind == "trivia" then
				local trivia = content:sub(span.start, span.finish)
				if span.start == 1 then trivia = trivia:gsub("^" .. QUICK_MARKER .. "[\r\n]*", "", 1) end
				slices[#slices + 1] = trivia
			elseif span.name == "node" or span.name == "subscription" or span.name == "experimental" then
				slices[#slices + 1] = content:sub(span.start, span.finish)
			end
		end
	end
	return revision(table.concat(slices, "\n"))
end

local function quick_known_subscriptions(content)
	local parsed = M.model(content).model
	local names = {}
	for _, item in ipairs(parsed.subscriptions or {}) do names[item.name] = true end
	return names
end

local function quick_valid_interfaces(discovery, lan, wan)
	local by_name, list = {}, discovery and discovery.interfaces or {}
	for _, item in ipairs(list) do if item.l3Device and item.l3Device ~= "" then by_name[item.l3Device] = item end end
	local l, w = by_name[lan], by_name[wan]
	if not l or not l.present or not l.up then return nil, "INTERFACE_AMBIGUOUS" end
	if not w or not w.present or not w.up then return nil, "INTERFACE_AMBIGUOUS" end
	if lan == wan then return nil, "INTERFACE_AMBIGUOUS" end
	return { lan = l, wan = w }
end

local function quick_geo_gate(preset)
	if preset == "direct" then return true, nil, nil end
	local labels = (preset == "gfwlist" and "gfw,private" or preset == "china-direct" and "cn,private" or "private")
	local output = sys.exec("DAE_LOCATION_ASSET=/usr/share/honk " .. shell_quote(HONK_TOOL) .. " geo capabilities --json --labels " .. labels .. " --geoip-labels cn 2>/dev/null") or ""
	local value = jsonc.parse(output)
	if type(value) ~= "table" or value.ok == false then
		local status = type(value) == "table" and value.diskStatus or "MISSING"
		if status == "V2FLY_GFW_UNSUPPORTED" then return nil, "GEO_V2FLY_UNSUPPORTED", value end
		if status == "TAMPERED" then return nil, "GEO_TAMPERED", value end
		return nil, "GEO_LABEL_MISSING", value
	end
	return true, nil, value
end

local function quick_render(input, content, partition, discovery)
	if type(input) ~= "table" then return nil, "INVALID_REQUEST" end
	for key in pairs(input) do
		if key ~= "preset" and key ~= "lanDevice" and key ~= "wanDevice" and key ~= "lan" and key ~= "wan" and key ~= "subscriptionNames" and key ~= "expectedRevision" and key ~= "replaceAdvanced" and key ~= "sessionId" then
			return nil, "UNKNOWN_FIELD"
		end
	end
	if type(input.preset) ~= "string" then return nil, "UNKNOWN_PRESET" end
	if input.replaceAdvanced ~= nil and type(input.replaceAdvanced) ~= "boolean" then return nil, "INVALID_REQUEST" end
	local preset = trim(input.preset)
	if not QUICK_PRESETS[preset] then return nil, "UNKNOWN_PRESET" end
	local lan, wan = trim(input.lanDevice or input.lan or ""), trim(input.wanDevice or input.wan or "")
	if lan == "" or wan == "" or lan == "auto" or wan == "auto" or not lan:match("^[%w_.:-]+$") or not wan:match("^[%w_.:-]+$") then return nil, "INTERFACE_AMBIGUOUS" end
	local interface_pair, interface_error = quick_valid_interfaces(discovery, lan, wan)
	if not interface_pair then return nil, interface_error end
	local selected, names = {}, quick_known_subscriptions(content)
	if input.subscriptionNames == nil then input.subscriptionNames = {} end
	if type(input.subscriptionNames) ~= "table" then return nil, "INVALID_REQUEST" end
	if #input.subscriptionNames > 32 then return nil, "SUBSCRIPTION_LIMIT" end
	for key in pairs(input.subscriptionNames) do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) or key > #input.subscriptionNames then return nil, "INVALID_REQUEST" end
	end
	local selected_names = {}
	for _, name in ipairs(input.subscriptionNames) do
		if type(name) ~= "string" or not names[name] then return nil, "SUBSCRIPTION_NOT_FOUND" end
		if selected_names[name] then return nil, "SUBSCRIPTION_DUPLICATE" end
		selected_names[name] = true
		selected[#selected + 1] = name
	end
	if preset ~= "direct" and #selected == 0 then return nil, "PROXY_GROUP_REQUIRED" end
	local geo_ok, geo_error = quick_geo_gate(preset)
	if not geo_ok then return nil, geo_error end
	if partition.advanced and input.replaceAdvanced ~= true then return nil, "ADVANCED_REPLACEMENT_REQUIRED" end
	local group = ""
	if preset ~= "direct" then
		local args = {}
		for _, name in ipairs(selected) do args[#args + 1] = dae_quote(name) end
		group = "group {\n\tquick-proxy {\n\t\tfilter: subscription(" .. table.concat(args, ",") .. ")\n\t\tpolicy: selector\n\t\tfinal: direct\n\t}\n}\n"
	end
	local route_lines
	if preset == "gfwlist" then
		route_lines = { "\tdip(geoip: private) -> direct(must)", "\tdomain(geosite: gfw) -> quick-proxy", "\tfallback: direct" }
	elseif preset == "china-direct" then
		route_lines = { "\tdip(geoip: private) -> direct(must)", "\tdip(geoip: cn) -> direct", "\tdomain(geosite: cn) -> direct", "\tfallback: quick-proxy" }
	elseif preset == "global" then route_lines = { "\tdip(geoip: private) -> direct(must)", "\tfallback: quick-proxy" }
	else route_lines = { "\tdip(geoip: private) -> direct(must)", "\tfallback: direct" } end
	local dns_target = preset == "direct" and "aliyun" or "google"
	local dns_fallback = preset == "china-direct" and "google" or (preset == "gfwlist" and "aliyun" or dns_target)
	local global = "global {\n\tlan_interface: " .. dae_quote(lan) .. "\n\twan_interface: " .. dae_quote(wan) .. "\n}\n"
	local google_line = preset == "direct" and "\t\tgoogle: 'tcp+udp://8.8.8.8:53'" or "\t\tgoogle: 'tcp+udp://8.8.8.8:53' -> quick-proxy"
	local dns = "dns {\n\tupstream {\n\t\taliyun: 'udp://223.5.5.5:53'\n" .. google_line .. "\n\t}\n\trouting {\n\t\trequest {\n\t\t\tfallback: " .. dns_fallback .. "\n\t\t}\n\t}\n}\n"
	if preset == "gfwlist" then dns = dns:gsub("fallback: aliyun", "qname(geosite: gfw) -> google\n\t\t\tfallback: aliyun") end
	if preset == "china-direct" then dns = dns:gsub("fallback: google", "qname(geosite: cn) -> aliyun\n\t\t\tfallback: google") end
	local preserved = {}
	for _, span in ipairs(partition.spans or {}) do
		if span.finish >= span.start then
			if span.kind == "trivia" then
				local trivia = content:sub(span.start, span.finish)
				if span.start == 1 then trivia = trivia:gsub("^" .. QUICK_MARKER .. "[\r\n]*", "", 1) end
				if trim(trivia) ~= "" then preserved[#preserved + 1] = trivia end
			elseif span.name == "node" or span.name == "subscription" or span.name == "experimental" then
				preserved[#preserved + 1] = content:sub(span.start, span.finish)
			end
		end
	end
	local candidate = QUICK_MARKER .. "\n" .. global .. group .. "routing {\n" .. table.concat(route_lines, "\n") .. "\n}\n" .. dns .. table.concat(preserved, "\n\n") .. "\n"
	return candidate, nil, { interface = interface_pair, selected = selected, preset = preset, compilerVersion = QUICK_COMPILER }
end

local function quick_discovery_call()
	local ok, ubus = pcall(require, "ubus")
	if not ok then return { ok = false, interfaces = {}, error = "UBUS_UNAVAILABLE" } end
	local connection = ubus.connect()
	if not connection then return { ok = false, interfaces = {}, error = "UBUS_UNAVAILABLE" } end
	local dump = connection:call("network.interface", "dump", {}) or {}
	local interfaces, by_device = {}, {}
	for _, item in ipairs(dump.interface or {}) do
		local l3 = trim(item.l3_device or "")
		local logical = trim(item.interface or item.name or "")
		local addresses = {}
		for _, address in ipairs(item["ipv4-address"] or {}) do addresses[#addresses + 1] = { family = "ipv4", address = address.address, prefix = tonumber(address.mask) or 0 } end
		for _, address in ipairs(item["ipv6-address"] or {}) do addresses[#addresses + 1] = { family = "ipv6", address = address.address, prefix = tonumber(address.mask) or 0 } end
		local defaults, best = {}, nil
		for _, route in ipairs(item.route or {}) do
			local target = route.target or route.dest
			if target == "0.0.0.0" or target == "::" or target == "0.0.0.0/0" or target == "::/0" then
				local metric = tonumber(route.metric) or 0
				defaults[#defaults + 1] = { family = target:find(":", 1, true) and "ipv6" or "ipv4", metric = metric }
				if not best or metric < best.metric then best = defaults[#defaults] end
			end
		end
		if l3 ~= "" then by_device[l3] = true end
		interfaces[#interfaces + 1] = { logicalName = logical, l3Device = l3, device = item.device, addresses = addresses, defaultRoute = best, defaultRoutes = defaults, selectedBy = logical == "lan" and "lan" or (best and "default-route" or "none"), safe = l3 ~= "", reasonCodes = l3 == "" and { "L3_DEVICE_MISSING" } or {}, present = false, up = false, kind = "unknown" }
	end
	for _, item in ipairs(interfaces) do
		local status = item.l3Device ~= "" and connection:call("network.device", "status", { name = item.l3Device }) or nil
		status = status or {}
		item.present = status.present ~= false and (status.present == true or status.exists == true or item.l3Device ~= "")
		item.up = status.up ~= false
		item.parent = status.parent
		item.kind = status.bridge and "bridge" or (item.l3Device:find("%.") and "vlan" or (item.l3Device:match("^br%-") and "bridge" or "device"))
		if #item.defaultRoutes > 1 then item.reasonCodes[#item.reasonCodes + 1] = "MULTIPLE_DEFAULT_ROUTES" end
		if not item.present then item.reasonCodes[#item.reasonCodes + 1] = "DEVICE_MISSING" end
		item.safe = item.safe and item.present and item.up
	end
	local lan, wan, wan_metric
	for _, item in ipairs(interfaces) do
		if item.logicalName == "lan" and item.safe and #item.addresses > 0 then lan = item end
		if item.defaultRoute and item.safe and (not wan_metric or item.defaultRoute.metric < wan_metric) then wan, wan_metric = item, item.defaultRoute.metric end
	end
	return { ok = true, interfaces = interfaces, recommended = { lan = lan and lan.l3Device or nil, wan = wan and wan.l3Device or nil }, ambiguous = not lan or not wan or lan.l3Device == wan.l3Device }
end

function M.network_discovery()
	return quick_discovery_call()
end

function M.quick_state()
	local content = read(CONFIG)
	local partition = quick_partition(content)
	local discovery = quick_discovery_call()
	local subscriptions = {}
	for _, item in ipairs(M.model(content).model.subscriptions or {}) do
		subscriptions[#subscriptions + 1] = { name = item.name, updateInterval = item.updateInterval, enabled = item.enabled }
	end
	local geo = jsonc.parse(sys.exec("DAE_LOCATION_ASSET=/usr/share/honk " .. shell_quote(HONK_TOOL) .. " geo capabilities --json 2>/dev/null") or "")
	return { ok = true, marker = partition and partition.marker or false, advancedOwned = partition and partition.advanced or true, reasons = partition and partition.reasons or { "PARTITION_FAILED" }, revision = revision(content), running = sys.call("pidof honk-core >/dev/null 2>&1") == 0, discovery = discovery, subscriptions = subscriptions, geo = geo or { ok = false, diskStatus = "MISSING", activeStatus = "STALE" }, presets = { { id = "gfwlist", requiresGeo = true }, { id = "china-direct", requiresGeo = true }, { id = "global", requiresGeo = false }, { id = "direct", requiresGeo = false } } }
end

function M.quick_preview(input)
	if type(input) ~= "table" then return error_response("INVALID_REQUEST", "structured Quick Setup input is required") end
	if type(input.expectedRevision) ~= "string" or input.expectedRevision == "" then return error_response("REVISION_REQUIRED", "full-file revision is required") end
	if type(input.sessionId) ~= "string" or input.sessionId == "" then return error_response("CSRF_OR_AUTH_REQUIRED", "authenticated session is required", 403) end
	local content, current = read(CONFIG), current_revision()
	if input.expectedRevision and input.expectedRevision ~= current then return error_response("REVISION_CONFLICT", "configuration changed; reload before preview", 409) end
	local partition = quick_partition(content)
	local discovery = quick_discovery_call()
	local candidate, error_code, metadata = quick_render(input, content, partition, discovery)
	if not candidate then return error_response(error_code, "Quick Setup prerequisites are not satisfied") end
	local valid, detail = M.validate(candidate)
	if not valid or not valid.ok then return error_response("INVALID_CONFIG", detail or "compiled configuration failed validation") end
	if not quick_prepare_dir() then return error_response("PREVIEW_FAILED", "unable to prepare preview directory", 500) end
	local nonce, expires = quick_nonce(), os.time() + 300
	local entry = { nonce = nonce, expires = expires, sourceRevision = current, candidate = candidate, candidateSha256 = revision(candidate), sourceSha256 = current, session = input.sessionId, input = { preset = input.preset, lanDevice = input.lanDevice or input.lan, wanDevice = input.wanDevice or input.wan, subscriptionNames = input.subscriptionNames or {}, replaceAdvanced = input.replaceAdvanced == true }, preset = metadata.preset, compilerVersion = QUICK_COMPILER, spanDigest = partition.spanDigest, preservedDigest = quick_preserved_digest(content, partition) }
	local path = QUICK_DIR .. "/" .. nonce .. ".json"
	if not fs.writefile(path, jsonc.stringify(entry)) then return error_response("PREVIEW_FAILED", "unable to persist preview", 500) end
	fs.chmod(path, 600)
	local additions, removals, diff = line_diff(content, candidate)
	return { ok = true, previewNonce = nonce, expiresAt = expires, candidateSha256 = entry.candidateSha256, sourceSha256 = current, spanDigest = entry.spanDigest, preservedDigest = entry.preservedDigest, compilerVersion = QUICK_COMPILER, projection = { preset = metadata.preset, lanDevice = input.lanDevice or input.lan, wanDevice = input.wanDevice or input.wan, subscriptionNames = metadata.selected, dns = metadata.preset == "direct" and "aliyun" or "google" }, diff = quick_redact(diff), additions = additions, removals = removals, blockedReasons = {} }
end

function M.quick_apply(input)
	if type(input) ~= "table" or type(input.previewNonce) ~= "string" or input.previewNonce == "" then return error_response("PREVIEW_NONCE_REQUIRED", "a preview nonce is required") end
	for key in pairs(input) do
		if key ~= "previewNonce" and key ~= "expectedRevision" and key ~= "sessionId" then return error_response("UNKNOWN_FIELD", "Quick Setup apply accepts only the preview nonce and revision") end
	end
	if not input.previewNonce:match("^[A-Fa-f0-9%-]+$") then return error_response("PREVIEW_EXPIRED", "preview nonce is invalid", 409) end
	if type(input.expectedRevision) ~= "string" or input.expectedRevision == "" then return error_response("REVISION_REQUIRED", "full-file revision is required") end
	if type(input.sessionId) ~= "string" or input.sessionId == "" then return error_response("CSRF_OR_AUTH_REQUIRED", "authenticated session is required", 403) end
	return (function()
		local path = QUICK_DIR .. "/" .. input.previewNonce
		if not path:match("%.json$") then path = path .. ".json" end
		local entry = jsonc.parse(read(path))
		if type(entry) ~= "table" or entry.nonce ~= input.previewNonce then return error_response("PREVIEW_EXPIRED", "preview nonce is invalid or expired", 409) end
		if tonumber(entry.expires or 0) < os.time() then return error_response("PREVIEW_EXPIRED", "preview nonce has expired", 409) end
		if entry.session == "" or input.sessionId ~= entry.session then return error_response("PREVIEW_SESSION_MISMATCH", "preview belongs to another session", 403) end
		local current = current_revision()
		if input.expectedRevision ~= current or entry.sourceRevision ~= current then return error_response("REVISION_CONFLICT", "configuration changed; preview it again", 409) end
		local regenerated
		if type(entry.input) == "table" then
			local source = read(CONFIG)
			local part = quick_partition(source)
			local fresh, render_error = quick_render(entry.input, source, part, quick_discovery_call())
			if not fresh or render_error then return error_response("PREVIEW_TAMPERED", "preview source no longer produces the same candidate", 409) end
			regenerated = fresh
		end
		local candidate = regenerated or entry.candidate
		if type(candidate) ~= "string" or revision(candidate) ~= entry.candidateSha256 then return error_response("PREVIEW_TAMPERED", "preview candidate failed integrity check", 409) end
		local worker = QUICK_WORKER
		if fs.access(worker) then
			local candidate_path = QUICK_DIR .. "/" .. input.previewNonce .. ".candidate"
			if not fs.writefile(candidate_path, candidate) then return error_response("TRANSACTION_FAILED", "unable to stage candidate", 500) end
			fs.chmod(candidate_path, 600)
			local output = sys.exec(shell_quote(worker) .. " --apply " .. shell_quote(candidate_path) .. " " .. shell_quote(current) .. " " .. shell_quote(input.previewNonce) .. " 2>&1") or ""
			local parsed = jsonc.parse(output)
			fs.remove(candidate_path)
			if type(parsed) == "table" and parsed.ok then fs.remove(path); return parsed end
			return error_response((type(parsed) == "table" and parsed.error and parsed.error.code) or "ROLLBACK", "Quick Setup transaction failed", 500)
		end
		return error_response("TRANSACTION_WORKER_UNAVAILABLE", "Quick Setup transaction worker is unavailable", 503)
	end)()
end

function M.geo_repair(confirm)
	if confirm ~= true then return error_response("GEO_REPAIR_CONFIRM_REQUIRED", "explicit repair confirmation is required") end
	local output = sys.exec(shell_quote(HONK_TOOL) .. " geo repair --json --confirm 2>&1") or ""
	local parsed = jsonc.parse(output)
	if type(parsed) == "table" and parsed.ok then return parsed end
	return error_response("GEO_REPAIR_FAILED", quick_redact(trim(output)), 500)
end

function M.transaction_status()
	local journal = jsonc.parse(read(QUICK_JOURNAL))
	return { ok = true, journal = journal, sidecar = fs.access(QUICK_SIDECAR) and true or false }
end

return M
