local fs = require "nixio.fs"
local nixio = require "nixio"
local sys = require "luci.sys"
local jsonc = require "luci.jsonc"

local config = require "luci.model.config"
local mode = require "luci.model.mode"
local node = require "luci.model.node"
local network = require "luci.model.honk_network"

local M = {}

local STATE = os.getenv("HONK_LUCI_STATE_PATH") or config.RUN_DIR .. "/luci-state.json"
local LOCK = os.getenv("HONK_LUCI_LOCK_PATH") or config.RUN_DIR .. "/luci-config.lock"
local INIT = os.getenv("HONK_INIT_PATH") or "/etc/init.d/honk"
local ASSET_DIR = os.getenv("HONK_ASSET_DIR") or "/usr/share/honk"
local HEALTH_ATTEMPTS = tonumber(os.getenv("HONK_HEALTH_ATTEMPTS")) or 10

local ERROR_MESSAGES = {
	MODE_UNKNOWN = "unknown routing mode",
	PROXY_SOURCE_INVALID = "proxy source selection is malformed",
	PROXY_SOURCE_REQUIRED = "select at least one node or subscription",
	PROXY_SOURCE_LIMIT = "too many proxy sources were selected",
	DIRECT_DNS_INVALID = "direct DNS upstream is invalid",
	PROXY_DNS_INVALID = "proxy DNS upstream is invalid",
	DEVICE_RULES_INVALID = "device rule list is invalid",
	DEVICE_RULE_INVALID = "device rule is invalid",
	DEVICE_IP_INVALID = "device IP or CIDR is invalid",
	DEVICE_MAC_INVALID = "device MAC address is invalid",
	DEVICE_RULE_DUPLICATE = "duplicate device rule",
	ADVANCED_TAKEOVER_REQUIRED = "custom routing is active; confirm Advanced configuration takeover",
	REVISION_REQUIRED = "configuration revision is required",
	REVISION_CONFLICT = "configuration changed; reload before applying",
	CONFIG_INVALID = "candidate configuration failed validation",
	GEO_DATA_MISSING = "required Geo data or labels are missing",
	WRITE_FAILED = "configuration replacement failed",
	SERVICE_FAILED = "service did not become healthy",
	ROLLBACK = "apply failed and the previous configuration was restored",
	ROLLBACK_DEGRADED = "apply failed and service recovery needs attention",
	LOCK_FAILED = "configuration operation is already in progress",
	SOURCE_ACTION_INVALID = "source action is invalid",
	SUBSCRIPTION_REFRESH_FAILED = "subscription refresh request failed",
	NODE_MISSING = "node is not available in the running catalog",
	CLASH_API_UNAVAILABLE = "Clash API is unavailable",
	CLASH_API_INVALID = "Clash API setting is invalid",
	DELAY_API_INVALID = "delay response is invalid",
	NODE_DELAY_FAILED = "node delay test failed",
	CONNECTIVITY_TARGET_INVALID = "connectivity target is invalid",
	CONNECTIVITY_FAILED = "connectivity test failed",
	DEFAULT_CONFIG_MISSING = "default configuration template is unavailable",
	INTERFACE_AMBIGUOUS = "network interfaces are ambiguous; choose LAN and WAN explicitly",
	INTERFACE_NOT_AVAILABLE = "selected network interface is no longer available",
	INTERFACE_SAME = "LAN and WAN must use different devices",
	DIAL_MODE_INVALID = "dial mode is invalid",
	NETWORK_DISCOVERY_FAILED = "network interface discovery failed",
}

local CONNECTIVITY_TARGETS = {
	{ id = "aliyun", url = "https://www.aliyun.com", route = "direct" },
	{ id = "google", url = "https://www.google.com/generate_204", route = "honk-proxy" },
	{ id = "github", url = "https://github.com", route = "honk-proxy" },
	{ id = "youtube", url = "https://www.youtube.com", route = "honk-proxy" },
}

local function error_result(code, detail, status, extra)
	local base = tostring(code or "INTERNAL_ERROR"):match("^([^:]+)") or "INTERNAL_ERROR"
	return config.error(base, detail or ERROR_MESSAGES[base] or code or "operation failed", status, extra)
end

local function running()
	return sys.call("pidof honk-core >/dev/null 2>&1") == 0
end

local function ensure_run_dir()
	if fs.access(config.RUN_DIR) then return true end
	return fs.mkdir(config.RUN_DIR) or fs.access(config.RUN_DIR)
end

local function read_state()
	local decoded = jsonc.parse(config.read(STATE))
	return type(decoded) == "table" and decoded or { stage = "none" }
end

local function write_state(value)
	ensure_run_dir()
	value.updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
	fs.writefile(STATE, jsonc.stringify(value))
	fs.chmod(STATE, 600)
end

local function with_lock(callback)
	if not ensure_run_dir() then return error_result("LOCK_FAILED", nil, 503) end
	local lock = nixio.open(LOCK, "w", 600)
	if not lock then return error_result("LOCK_FAILED", nil, 503) end
	local acquired = lock:lock("lock")
	if not acquired then lock:close(); return error_result("LOCK_FAILED", nil, 503) end
	local called, result, status = pcall(callback)
	lock:close()
	if not called then return error_result("INTERNAL_ERROR", "configuration operation failed", 500) end
	return result, status
end

local function geo_check(mode_name)
	local requirements = mode.geo_requirements(mode_name)
	if not requirements then return true, { ok = true, skipped = true } end
	local command = "DAE_LOCATION_ASSET=" .. config.shell_quote(ASSET_DIR) .. " " .. config.shell_quote(config.HONK_TOOL) .. " geo capabilities --json"
	if #(requirements.geoSite or {}) > 0 then command = command .. " --labels " .. config.shell_quote(table.concat(requirements.geoSite, ",")) end
	if #(requirements.geoIp or {}) > 0 then command = command .. " --geoip-labels " .. config.shell_quote(table.concat(requirements.geoIp, ",")) end
	command = command .. " 2>&1"
	local output = sys.exec(command) or ""
	local decoded = jsonc.parse(output)
	return type(decoded) == "table" and decoded.ok ~= false, type(decoded) == "table" and decoded or { ok = false, detail = config.redact(output) }
end

local function diff_counts(before, after)
	local old, new = {}, {}
	for line in (before .. "\n"):gmatch("([^\n]*)\n") do old[#old + 1] = line end
	for line in (after .. "\n"):gmatch("([^\n]*)\n") do new[#new + 1] = line end
	local additions, removals = 0, 0
	for index = 1, math.max(#old, #new) do
		if old[index] ~= new[index] then
			if old[index] ~= nil then removals = removals + 1 end
			if new[index] ~= nil then additions = additions + 1 end
		end
	end
	return additions, removals
end

local function compile(input)
	local content = config.read()
	local compiled, compile_error = mode.compile(content, input)
	if not compiled then return nil, compile_error, content end
	return compiled, nil, content
end

local function clash_api_status(content)
	local experimental = config.section(content, "experimental")
	if not experimental then
		return { enabled = false, controller = "", port = nil, secretConfigured = false }
	end
	local body = config.section_body(content, experimental)
	local clash = config.section(body, "clash_api")
	if not clash then
		return { enabled = false, controller = "", port = nil, secretConfigured = false }
	end
	local values = config.key_values(config.section_body(body, clash))
	local controller = config.trim(values.external_controller or "")
	local port = tonumber(controller:match(":(%d+)$"))
	return {
		enabled = controller ~= "" and port ~= nil,
		controller = controller,
		port = port,
		secretConfigured = config.trim(values.secret or "") ~= "",
	}
end

local function replace_body_key(body, key, value)
	local wrapped = "\n" .. (body or "")
	local pattern = "\n([ \t]*)" .. key .. "([ \t]*:[ \t]*)[^\n]*"
	local updated, count = wrapped:gsub(pattern, function(spaces, separator)
		return "\n" .. spaces .. key .. separator .. value
	end, 1)
	if count > 0 then return updated:sub(2) end
	local trailing = (body or ""):match("(%s*)$") or ""
	local head = (body or ""):sub(1, #(body or "") - #trailing)
	if trailing == "" then trailing = "\n\t" end
	return head .. "\n\t\t" .. key .. ": " .. value .. trailing
end

local function clash_api_candidate(content, enabled)
	local experimental = config.section(content, "experimental")
	local desired_controller = ""
	if experimental then
		local body = config.section_body(content, experimental)
		local clash = config.section(body, "clash_api")
		if clash then
			local values = config.key_values(config.section_body(body, clash))
			desired_controller = config.trim(values.external_controller or "")
		end
	end
	if enabled then
		if desired_controller == "" then desired_controller = "127.0.0.1:9090" end
	else
		desired_controller = ""
	end
	if not experimental then
		local block = "\tclash_api {\n\t\texternal_controller: " .. config.dae_quote(desired_controller) .. "\n\t\texternal_ui: '/www/luci-static/resources/honk/app'\n\t\tsecret: ''\n\t\tdefault_mode: 'Rule'\n\t}"
		return config.replace_nested_section(content, "experimental", "clash_api", block)
	end
	local body = config.section_body(content, experimental)
	local clash = config.section(body, "clash_api")
	local block
	if clash then
		local clash_body = replace_body_key(config.section_body(body, clash), "external_controller", config.dae_quote(desired_controller))
		block = "\tclash_api {" .. clash_body .. "}"
	else
		block = "\tclash_api {\n\t\texternal_controller: " .. config.dae_quote(desired_controller) .. "\n\t}"
	end
	return config.replace_nested_section(content, "experimental", "clash_api", block)
end

function M.preview(input)
	local compiled, compile_error, content = compile(input)
	if not compiled then return error_result(compile_error, nil, 400) end
	local geo_ok, geo = geo_check(compiled.mode)
	if not geo_ok then return error_result("GEO_DATA_MISSING", nil, 422, { geo = geo }) end
	local valid, detail, validation = config.validate(compiled.candidate)
	if not valid then return error_result("CONFIG_INVALID", detail, 422, { validation = validation }) end
	local additions, removals = diff_counts(content, compiled.candidate)
	return {
		ok = true,
		mode = compiled.mode,
		previousMode = compiled.previousMode,
		requiresTakeover = compiled.requiresTakeover,
		expectedRevision = config.file_revision(),
		candidateRevision = config.revision(compiled.candidate),
		selected = compiled.selected,
		deviceRules = compiled.deviceRules,
		routing = compiled.routingLines,
		dns = compiled.dnsRules,
		changes = { additions = additions, removals = removals },
		geo = geo,
	}
end

local function health_check()
	for _ = 1, HEALTH_ATTEMPTS do
		if running() then return true end
		if nixio.nanosleep then nixio.nanosleep(0, 200000000) end
	end
	return false
end

local function transition(was_running)
	local action = was_running and "restart" or "start"
	local code = sys.call(config.shell_quote(INIT) .. " " .. action .. " >/dev/null 2>&1")
	return code == 0 and health_check(), action
end

local function restore(previous, was_running)
	local written = config.write_atomic(previous)
	if not written then return false end
	local action = was_running and "restart" or "stop"
	local code = sys.call(config.shell_quote(INIT) .. " " .. action .. " >/dev/null 2>&1")
	if code ~= 0 then return false end
	return not was_running or health_check()
end

function M.apply_content(candidate, expected_revision, metadata)
	if type(expected_revision) ~= "string" then return error_result("REVISION_REQUIRED") end
	if type(candidate) ~= "string" or #candidate > config.MAX_BYTES then return error_result("CONFIG_INVALID") end
	local valid, detail, validation = config.validate(candidate)
	if not valid then return error_result("CONFIG_INVALID", detail, 422, { validation = validation }) end
	return with_lock(function()
		local current_revision = config.file_revision()
		if current_revision ~= expected_revision then return error_result("REVISION_CONFLICT", nil, 409) end
		local previous = config.read()
		local was_running = running()
		local previous_valid = config.validate(previous)
		if previous_valid then
			fs.writefile(config.BACKUP, previous)
			fs.chmod(config.BACKUP, 600)
		end
		write_state({ stage = "validated", previousRevision = current_revision, wasRunning = was_running, metadata = metadata or {} })
		local replaced, replace_error = config.write_atomic(candidate)
		if not replaced then
			write_state({ stage = "write-failed", recentError = replace_error, rollback = false })
			return error_result("WRITE_FAILED", replace_error, 500)
		end
		write_state({ stage = "service-transition", previousRevision = current_revision, candidateRevision = config.file_revision(), wasRunning = was_running, metadata = metadata or {} })
		local healthy, action = transition(was_running)
		if healthy then
			local active = config.file_revision()
			local selection_synchronized
			local selected = metadata and metadata.selected
			if metadata and metadata.type == "mode" and type(selected) == "table" and
				type(selected.nodes) == "table" and #selected.nodes == 1 and
				type(selected.subscriptions) == "table" and #selected.subscriptions == 0 then
				selection_synchronized = node.set_group_selection(candidate, "honk-proxy", selected.nodes[1])
			end
			local committed_metadata = metadata or {}
			if selection_synchronized ~= nil then committed_metadata.selectionSynchronized = selection_synchronized end
			write_state({ stage = "committed", activeRevision = active, action = action, rollback = false, metadata = committed_metadata })
			return { ok = true, applied = true, action = action, revision = active, running = true, rollback = false, selectionSynchronized = selection_synchronized }
		end
		write_state({ stage = "rollback", previousRevision = current_revision, recentError = ERROR_MESSAGES.SERVICE_FAILED, rollback = true, metadata = metadata or {} })
		if restore(previous, was_running) then
			write_state({ stage = "restored", activeRevision = config.file_revision(), recentError = ERROR_MESSAGES.SERVICE_FAILED, rollback = true, metadata = metadata or {} })
			return error_result("ROLLBACK", nil, 500, { rollback = true, restored = true })
		end
		write_state({ stage = "degraded", activeRevision = config.file_revision(), recentError = ERROR_MESSAGES.ROLLBACK_DEGRADED, rollback = true, metadata = metadata or {} })
		return error_result("ROLLBACK_DEGRADED", nil, 500, { rollback = true, restored = false })
	end)
end

function M.default_config()
	local content = config.read_default()
	if content == "" then return error_result("DEFAULT_CONFIG_MISSING", nil, 503) end
	return {
		ok = true,
		content = content,
		revision = config.file_revision(),
		templateRevision = config.revision(content),
	}
end

function M.reset_config(input)
	if type(input) ~= "table" then return error_result("REVISION_REQUIRED") end
	local content = config.read_default()
	if content == "" then return error_result("DEFAULT_CONFIG_MISSING", nil, 503) end
	return M.apply_content(content, input.expectedRevision, { type = "reset-default" })
end

function M.apply(input)
	local compiled, compile_error = compile(input)
	if not compiled then return error_result(compile_error, nil, 400) end
	if compiled.requiresTakeover and input.takeover ~= true then return error_result("ADVANCED_TAKEOVER_REQUIRED", nil, 409, { requiresTakeover = true }) end
	local geo_ok, geo = geo_check(compiled.mode)
	if not geo_ok then return error_result("GEO_DATA_MISSING", nil, 422, { geo = geo }) end
	return M.apply_content(compiled.candidate, input.expectedRevision, { type = "mode", mode = compiled.mode, selected = compiled.selected })
end

function M.state(include_config)
	local content = config.read()
	local current_mode, managed = mode.detect(content)
	local last = read_state()
	local catalog = node.catalog(content)
	local revision = config.file_revision()
	local is_running = running()
	local runtime = node.runtime_catalog(content)
	catalog.subscriptionNodes = runtime.nodes
	catalog.runtimeAvailable = runtime.available
	catalog.runtimeConfigured = runtime.configured
	local result = {
		ok = true,
		running = is_running,
		revision = revision,
		activeRevision = is_running and (last.activeRevision or revision) or (last.activeRevision or ""),
		dirty = is_running and last.activeRevision ~= nil and last.activeRevision ~= revision,
		mode = current_mode,
		managed = managed,
		requiresTakeover = not managed,
		catalog = catalog,
		selected = mode.selected(content),
		deviceRules = mode.device_rules(content),
		last = last,
		recentError = last.recentError,
		rollback = last.rollback == true,
		backupAvailable = fs.access(config.BACKUP) and true or false,
		clashApi = clash_api_status(content),
	}
	if include_config then result.config = content end
	return result
end

function M.advanced()
	return M.state(true)
end

function M.toggle_clash_api(input)
	if type(input) ~= "table" or type(input.enabled) ~= "boolean" then
		return error_result("CLASH_API_INVALID", nil, 400)
	end
	if type(input.expectedRevision) ~= "string" or input.expectedRevision == "" then
		return error_result("REVISION_REQUIRED", nil, 400)
	end
	local current = config.read()
	local status = clash_api_status(current)
	if status.enabled == input.enabled then
		return { ok = true, changed = false, enabled = status.enabled, revision = config.file_revision(), clashApi = status }
	end
	local candidate, candidate_error = clash_api_candidate(current, input.enabled)
	if not candidate then return error_result("CLASH_API_INVALID", candidate_error, 422) end
	local result, code = M.apply_content(candidate, input.expectedRevision, { type = "clash_api", enabled = input.enabled })
	if type(result) == "table" and result.ok then
		result.enabled = input.enabled
		result.changed = true
		result.clashApi = clash_api_status(config.read())
	end
	return result, code
end

function M.validate_advanced(content)
	local valid, detail, validation = config.validate(content)
	if not valid then return error_result("CONFIG_INVALID", detail, 422, { validation = validation }) end
	return { ok = true, valid = true, revision = config.revision(content) }
end

function M.apply_advanced(input)
	if type(input) ~= "table" or type(input.config) ~= "string" then return error_result("CONFIG_INVALID") end
	return M.apply_content(input.config, input.expectedRevision, { type = "advanced" })
end

function M.network_interfaces()
	local result = network.snapshot(config.read())
	if not result.ok then return error_result("NETWORK_DISCOVERY_FAILED", result.error, 503, { discovery = result }) end
	return result
end

function M.apply_interfaces(input)
	if type(input) ~= "table" then return error_result("INTERFACE_AMBIGUOUS") end
	if type(input.expectedRevision) ~= "string" or input.expectedRevision == "" then
		return error_result("REVISION_REQUIRED")
	end
	local content = config.read()
	local discovery = network.discover()
	if not discovery.ok then return error_result("NETWORK_DISCOVERY_FAILED", discovery.error, 503, { discovery = discovery }) end
	local current = network.current(content)
	local selected, selection_error = network.validate_selection(
		discovery,
		input.lanDevice or input.lan or current.lan,
		input.wanDevice or input.wan or current.wan,
		input.dialMode or current.dialMode
	)
	if not selected then return error_result(selection_error, nil, 422, { discovery = discovery }) end
	local candidate, update_error = network.update_global(content, selected)
	if not candidate then return error_result("CONFIG_INVALID", update_error, 422) end
	local result, status = M.apply_content(candidate, input.expectedRevision, {
		type = "interfaces",
		lanDevice = selected.lan,
		wanDevice = selected.wan,
		dialMode = selected.dialMode,
	})
	if type(result) == "table" and result.ok then
		result.interfaces = { lan = selected.lan, wan = selected.wan }
		result.dialMode = selected.dialMode
		result.config = config.read()
	end
	return result, status
end

function M.mutate_source(input)
	local content = config.read()
	local candidate, mutation_error = node.mutate(content, input)
	if not candidate then return error_result(mutation_error, nil, 400) end
	return M.apply_content(candidate, input.expectedRevision, { type = "source", action = input.action, name = input.name })
end

function M.refresh_subscription(input)
	if type(input) ~= "table" or type(input.name) ~= "string" then
		return error_result("SUBSCRIPTION_REFRESH_FAILED", nil, 400)
	end
	local catalog = node.catalog(config.read())
	local found = false
	for _, item in ipairs(catalog.subscriptions) do
		if item.name == input.name then found = true; break end
	end
	if not found then return error_result("SUBSCRIPTION_REFRESH_FAILED", "subscription not found", 404) end
	local ok, detail = node.refresh_subscription(config.read(), input.name)
	if not ok then return error_result("SUBSCRIPTION_REFRESH_FAILED", detail, 503) end
	return { ok = true, accepted = true, name = input.name }
end

function M.delay(input)
	if type(input) ~= "table" or type(input.name) ~= "string" or input.name == "" then
		return error_result("NODE_MISSING", nil, 400)
	end
	local result, delay_error = node.delay(config.read(), input.name)
	if not result then
		local raw_error = tostring(delay_error or "NODE_DELAY_FAILED")
		local code, detail = "NODE_DELAY_FAILED", raw_error
		for _, known in ipairs({ "NODE_MISSING", "CLASH_API_UNAVAILABLE", "DELAY_API_INVALID", "NODE_DELAY_FAILED" }) do
			if raw_error == known or raw_error:sub(1, #known + 1) == known .. ":" then
				code, detail = known, raw_error:sub(#known + 2)
				if detail == "" then detail = nil end
				break
			end
		end
		return error_result(code, detail, 503)
	end
	return { ok = true, name = result.name, delay = result.delay, target = result.target }
end

local function connectivity_target(target)
	local command = table.concat({
		"/usr/bin/curl -I -o /dev/null -skL",
		"--connect-timeout 3 --max-time 8",
		"-w %{http_code}:%{time_pretransfer}",
		config.shell_quote(target.url),
		"2>/dev/null",
	}, " ")
	local output = sys.exec(command) or ""
	local status, seconds = output:match("^(%d+):([%d%.]+)")
	status, seconds = tonumber(status), tonumber(seconds)
	local latency = seconds and math.floor(seconds * 1000 + 0.5) or nil
	-- Any HTTP response proves that DNS/TCP/TLS reached the target. A target
	-- may reject HEAD (for example with 403) while still being reachable.
	local ok = status ~= nil and status >= 100 and status < 600
	local result = {
		id = target.id,
		url = target.url,
		route = target.route,
		ok = ok,
		status = status or 0,
		latency = latency,
	}
	if not ok then result.error = "request failed" end
	return result
end

local function proxy_connectivity_target(content, target)
	local response, detail = node.proxy_delay(content, "honk-proxy", target.url)
	local result = {
		id = target.id,
		url = target.url,
		route = target.route,
		ok = response ~= nil,
		status = response and 200 or 0,
		latency = response and response.delay or nil,
	}
	if not result.ok then result.error = detail or "proxy request failed" end
	return result
end

function M.connectivity(input)
	if not running() then return error_result("SERVICE_FAILED", nil, 503) end
	local target_id = type(input) == "table" and config.trim(input.id or "") or ""
	local target
	for _, candidate in ipairs(CONNECTIVITY_TARGETS) do
		if candidate.id == target_id then
			target = candidate
			break
		end
	end
	if not target then return error_result("CONNECTIVITY_TARGET_INVALID", nil, 400) end
	local result
	if target.route == "direct" then
		result = connectivity_target(target)
	else
		result = proxy_connectivity_target(config.read(), target)
	end
	return {
		ok = true,
		passed = result.ok,
		check = result,
		testedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
end

function M.service(action)
	if not ({ start = true, stop = true, restart = true })[action] then return error_result("SOURCE_ACTION_INVALID", "unsupported service action") end
	local code = sys.call(config.shell_quote(INIT) .. " " .. action .. " >/dev/null 2>&1")
	if code ~= 0 then return error_result("SERVICE_FAILED", "service action failed", 500) end
	local healthy = action == "stop" and not running() or health_check()
	if not healthy then return error_result("SERVICE_FAILED", nil, 500) end
	local last = read_state()
	last.stage = action == "stop" and "stopped" or "running"
	last.activeRevision = action == "stop" and last.activeRevision or config.file_revision()
	last.recentError = nil
	write_state(last)
	return { ok = true, action = action, state = M.state(false) }
end

local function clean_log_output(value)
	local output = tostring(value or "")
	-- tracing_subscriber writes ANSI SGR/OSC sequences when the log is
	-- redirected to a file. Keep UTF-8 node names intact, but remove terminal
	-- controls before the bytes reach JSON and the browser.
	output = output:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
	output = output:gsub("\27%][^\7]*\7", "")
	output = output:gsub("\27", "")
	output = output:gsub("\r", "")
	output = output:gsub("[%z\001-\008\011\012\014-\031\127]", "")
	return output
end

local function localize_log_timestamps(value)
	local function replace_timestamp(stamp, fraction)
		local year, month, day, hour, minute, second = stamp:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)$")
		local parsed = os.time({
			year = tonumber(year), month = tonumber(month), day = tonumber(day),
			hour = tonumber(hour), min = tonumber(minute), sec = tonumber(second),
			isdst = false,
		})
		if not parsed then return stamp .. (fraction or "") .. "Z" end

		-- Interpret the UTC fields once as local time, then add the local
		-- offset reported by libc. This follows /etc/TZ without a shell date
		-- subprocess and also handles a DST transition at the log timestamp.
		local offset = os.difftime(os.time(os.date("*t", parsed)), os.time(os.date("!*t", parsed)))
		local rendered = os.date("%Y-%m-%dT%H:%M:%S%z", parsed + offset)
		if not rendered then return stamp .. (fraction or "") .. "Z" end
		local base, zone = rendered:match("^(.-)([+-]%d%d%d%d)$")
		if not base then return stamp .. (fraction or "") .. "Z" end
		return base .. (fraction or "") .. zone
	end

	local output = tostring(value or "")
	output = output:gsub("(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)(%.[%d]+)Z", replace_timestamp)
	return output:gsub("(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)Z", replace_timestamp)
end

function M.logs()
	local output = sys.exec("tail -n 300 /tmp/honk/honk.log 2>/dev/null") or ""
	local cleaned = clean_log_output(output)
	return { ok = true, lines = config.redact(localize_log_timestamps(cleaned)) }
end

function M.diagnostics()
	local content = config.read()
	local current_mode = mode.detect(content)
	local valid, detail, validation = config.validate(content)
	local geo_ok, geo = geo_check(current_mode)
	return {
		ok = true,
		service = { running = running(), init = fs.access(INIT) and true or false },
		config = { valid = valid, detail = detail, revision = config.file_revision(), bytes = #content },
		geo = { valid = geo_ok, detail = geo },
		files = { config = fs.access(config.CONFIG) and true or false, backup = fs.access(config.BACKUP) and true or false, tool = fs.access(config.HONK_TOOL) and true or false },
		validation = validation,
		last = read_state(),
	}
end

return M
