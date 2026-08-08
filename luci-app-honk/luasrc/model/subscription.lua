local fs = require "nixio.fs"
local nixio = require "nixio"
local jsonc = require "luci.jsonc"
local sys = require "luci.sys"
local uci = require "luci.model.uci"

local config = require "luci.model.config"

local M = {}

M.CACHE_DIR = os.getenv("HONK_SUBSCRIPTION_CACHE_DIR") or "/etc/honk/subscriptions"
local function ttl()
	local configured = tonumber(os.getenv("HONK_SUBSCRIPTION_CACHE_TTL"))
	if configured then return math.max(0, configured) end
	local value = tonumber(uci.cursor():get("honk", "main", "subscription_cache_ttl"))
	return math.max(0, value or 604800)
end

local function safe_name(name)
	local value = tostring(name or ""):gsub("[^%w_.-]", "_")
	if value == "" or value == "." or value == ".." then return nil end
	return value
end

local function paths(name)
	local safe = safe_name(name)
	if not safe then return nil end
	return {
		raw = M.CACHE_DIR .. "/" .. safe .. ".sub",
		meta = M.CACHE_DIR .. "/" .. safe .. ".json",
	}
end

local function ensure_dir()
	if not fs.access(M.CACHE_DIR) and not fs.mkdir(M.CACHE_DIR) and not fs.access(M.CACHE_DIR) then return false end
	return fs.chmod(M.CACHE_DIR, 700) and true or false
end

local function temporary(prefix)
	return "/tmp/honk-" .. prefix .. "-" .. tostring(nixio.getpid and nixio.getpid() or math.random(1000, 9999))
end

local function read_record(name)
	local target = paths(name)
	if not target then return nil end
	local record = jsonc.parse(fs.readfile(target.meta) or "")
	if type(record) ~= "table" then return nil end
	if type(record.nodes) ~= "table" then record.nodes = {} end
	local updated = tonumber(record.updatedEpoch) or 0
	local missing = updated <= 0 or next(record.nodes) == nil
	record.nodeCount = missing and 0 or tonumber(record.nodeCount) or #record.nodes
	record.stale = not missing and os.time() - updated > ttl() or false
	record.source = missing and "missing" or (record.stale and "stale" or "cache")
	return record
end

local function raw_fetch(url, target)
	local command = table.concat({
		"/usr/bin/curl -fsSL --max-filesize 1048576",
		"--connect-timeout 10 --max-time 30",
		"-o", config.shell_quote(target),
		config.shell_quote(url),
		"2>/dev/null",
	}, " ")
	return sys.call(command) == 0 and fs.access(target)
end

local function tool_nodes(source, payload_file)
	local command = config.shell_quote(config.HONK_TOOL) .. " sub --format json"
	if payload_file then command = command .. " --payload-file " .. config.shell_quote(payload_file) end
	command = command .. " " .. config.shell_quote(source) .. " 2>&1"
	local output = sys.exec(command) or ""
	local json = output:match("(%b[])%s*$")
	local nodes = json and jsonc.parse(json) or nil
	if type(nodes) ~= "table" then
		return nil, "subscription parse failed"
	end
	local normalized = {}
	for _, item in pairs(nodes) do
		if type(item) == "table" and type(item.name) == "string" and item.name ~= "" then
			normalized[#normalized + 1] = {
				name = item.name,
				protocol = tostring(item.protocol or "unknown"):lower(),
				address = item.address,
				host = item.host,
				port = tonumber(item.port),
			}
		end
	end
	if #normalized == 0 then return nil, "no supported nodes found" end
	table.sort(normalized, function(a, b) return a.name < b.name end)
	return normalized
end

local function write_atomic(path, value)
	local temp = path .. ".tmp-" .. tostring(nixio.getpid and nixio.getpid() or math.random(1000, 9999))
	if not fs.writefile(temp, value) then return false end
	if not fs.chmod(temp, 600) then
		fs.remove(temp)
		return false
	end
	if fs.rename(temp, path) then return true end
	fs.remove(temp)
	return false
end

local function record_error(name, detail)
	local target = paths(name)
	if not target then return end
	local record = read_record(name)
	if not record then
		record = { name = name, nodeCount = 0, nodes = {}, updatedEpoch = 0 }
	end
	record.lastError = config.redact(detail or "subscription refresh failed")
	record.lastErrorAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
	if record.source == "missing" then
		record.stale = false
		record.source = "missing"
	end
	write_atomic(target.meta, jsonc.stringify(record))
end

function M.refresh(name, url)
	local target = paths(name)
	if not target or type(url) ~= "string" or url == "" then return nil, "invalid subscription" end
	if not ensure_dir() then return nil, "subscription cache directory is unavailable" end

	local raw_temp = temporary("subscription")
	fs.remove(raw_temp)
	local source, payload_file = raw_temp, nil
	local raw_content
	if url:match("^https?://") then
		if not raw_fetch(url, raw_temp) then
			fs.remove(raw_temp)
			record_error(name, "subscription download failed")
			return nil, "subscription download failed"
		end
		raw_content = fs.readfile(raw_temp) or ""
		-- Use the exact first response for parsing and persistence. The source
		-- URL is retained as metadata, but honk-tool must not fetch it again.
		source = url
		payload_file = raw_temp
	else
		if not url:match("^[%w+.-]+://") then
			fs.remove(raw_temp)
			record_error(name, "unsupported subscription link")
			return nil, "unsupported subscription link"
		end
		if not fs.writefile(raw_temp, url .. "\n") then
			fs.remove(raw_temp)
			record_error(name, "subscription staging failed")
			return nil, "subscription staging failed"
		end
		raw_content = url .. "\n"
	end

	local nodes, parse_error = tool_nodes(source, payload_file)
	fs.remove(raw_temp)
	if not nodes then
		local detail = parse_error or "subscription parse failed"
		record_error(name, detail)
		return nil, config.redact(detail)
	end
	if raw_content == "" then
		record_error(name, "subscription is empty")
		return nil, "subscription is empty"
	end

	local now = os.time()
	local record = {
		name = name,
		nodeCount = #nodes,
		nodes = nodes,
		updatedEpoch = now,
		updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ", now),
		lastError = nil,
	}
	if not write_atomic(target.raw, raw_content) then
		record_error(name, "subscription cache write failed")
		return nil, "subscription cache write failed"
	end
	record.sha256 = config.trim(sys.exec("sha256sum " .. config.shell_quote(target.raw) .. " 2>/dev/null | cut -d ' ' -f 1") or "")
	if not write_atomic(target.meta, jsonc.stringify(record)) then
		record_error(name, "subscription metadata write failed")
		return nil, "subscription metadata write failed"
	end
	return record
end

function M.cache(name)
	return read_record(name)
end

function M.remove(name)
	local target = paths(name)
	if not target then return false end
	fs.remove(target.raw)
	fs.remove(target.meta)
	return true
end

local function same_nodes(current, observed)
	if #current ~= #observed then return false end
	for index, item in ipairs(current) do
		local candidate = observed[index]
		if item.name ~= candidate.name or item.protocol ~= candidate.protocol then return false end
	end
	return true
end

-- The Clash API is the only source for a runtime subscription merge. Persist
-- its compact node view so stopping Honk from LuCI does not empty the Nodes
-- page when a subscription has not been refreshed manually yet.
function M.capture_runtime(catalog, runtime_nodes)
	if type(catalog) ~= "table" or type(runtime_nodes) ~= "table" then return false end
	if not ensure_dir() then return false end

	local configured, observed = {}, {}
	for _, item in ipairs(catalog.subscriptions or {}) do
		if type(item) == "table" and type(item.name) == "string" and item.name ~= "" and item.enabled ~= false then
			configured[item.name] = true
			observed[item.name] = {}
		end
	end
	for _, item in ipairs(runtime_nodes) do
		if type(item) == "table" and configured[item.subscription] and type(item.name) == "string" and item.name ~= "" then
			observed[item.subscription][#observed[item.subscription] + 1] = {
				name = item.name,
				protocol = tostring(item.protocol or "unknown"):lower(),
			}
		end
	end

	local changed = false
	for name, nodes in pairs(observed) do
		if #nodes > 0 then
			table.sort(nodes, function(a, b) return a.name < b.name end)
			local record = read_record(name) or { name = name, nodes = {}, nodeCount = 0, updatedEpoch = 0 }
			if not same_nodes(record.nodes or {}, nodes) then
				local now = os.time()
				record.nodes = nodes
				record.nodeCount = #nodes
				record.updatedEpoch = now
				record.updatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ", now)
				record.snapshot = "runtime"
				record.source = nil
				record.stale = nil
				if write_atomic(paths(name).meta, jsonc.stringify(record)) then changed = true end
			end
		end
	end
	return changed
end

function M.catalog(catalog)
	local cached_nodes = {}
	local subscriptions = catalog.subscriptions or {}
	for _, item in ipairs(subscriptions) do
		local record = read_record(item.name)
		if record then
			item.cacheSource = record.source
			item.cachedAt = record.updatedAt
			item.cachedNodeCount = record.nodeCount or #record.nodes
			item.cachedError = record.lastError
			item.cachedErrorAt = record.lastErrorAt
			for _, cached in ipairs(record.nodes) do
				cached_nodes[#cached_nodes + 1] = {
					name = cached.name,
					protocol = cached.protocol or "unknown",
					subscription = item.name,
					source = record.source,
				}
			end
		end
	end
	table.sort(cached_nodes, function(a, b) return a.name < b.name end)
	return cached_nodes
end

return M
