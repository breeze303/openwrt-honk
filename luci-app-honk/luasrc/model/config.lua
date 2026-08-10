local fs = require "nixio.fs"
local nixio = require "nixio"
local jsonc = require "luci.jsonc"

local M = {}

M.CONFIG = os.getenv("HONK_CONFIG_PATH") or "/etc/honk/config.dae"
M.DEFAULT_CONFIG = os.getenv("HONK_DEFAULT_CONFIG_PATH") or "/etc/honk/config.dae.default"
M.BACKUP = os.getenv("HONK_BACKUP_PATH") or "/etc/honk/config.dae.last-good"
M.RUN_DIR = os.getenv("HONK_RUN_DIR") or "/run/honk"
M.HONK_TOOL = os.getenv("HONK_TOOL_PATH") or "/usr/bin/honk-tool"
M.MAX_BYTES = 1048576

function M.trim(value)
	return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.shell_quote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

function M.dae_quote(value)
	return "'" .. tostring(value or ""):gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

function M.unquote(value)
	value = M.trim(value)
	if #value >= 2 then
		local first, last = value:sub(1, 1), value:sub(-1)
		if (first == "'" and last == "'") or (first == '"' and last == '"') then
			return value:sub(2, -2)
		end
	end
	return value
end

function M.read(path)
	return fs.readfile(path or M.CONFIG) or ""
end

function M.read_default()
	return fs.readfile(M.DEFAULT_CONFIG) or ""
end

function M.error(code, message, status, extra)
	local result = { ok = false, error = { code = code, message = message } }
	for key, value in pairs(extra or {}) do result[key] = value end
	return result, status or 400
end

local function section_close(content, open)
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

function M.parse(content)
	if type(content) ~= "string" then return nil, "configuration must be text" end
	local sections, by_name, index, length = {}, {}, 1, #content
	while index <= length do
		local searching = true
		while searching and index <= length do
			local char = content:sub(index, index)
			if char:match("%s") then
				index = index + 1
			elseif char == "#" then
				local newline = content:find("\n", index, true)
				index = newline and newline + 1 or length + 1
			else
				searching = false
			end
		end
		if index <= length then
			local name = content:sub(index):match("^([%a_][%w_-]*)")
			if not name then return nil, "unsupported top-level token at byte " .. tostring(index) end
			local open = index + #name
			while open <= length and content:sub(open, open):match("%s") do open = open + 1 end
			if content:sub(open, open) ~= "{" then
				return nil, "section " .. name .. " is missing an opening brace"
			end
			local close = section_close(content, open)
			if not close then return nil, "section " .. name .. " is missing a closing brace" end
			local section = { name = name, start = index, open = open, close = close, finish = close }
			sections[#sections + 1] = section
			by_name[name] = by_name[name] or {}
			by_name[name][#by_name[name] + 1] = section
			index = close + 1
		end
	end
	return { content = content, sections = sections, byName = by_name }, nil
end

function M.section(content, name)
	local parsed, err = M.parse(content)
	if not parsed then return nil, err end
	local list = parsed.byName[name] or {}
	if #list > 1 then return nil, "duplicate " .. name .. " section" end
	return list[1], nil
end

function M.section_body(content, section)
	return section and content:sub(section.open + 1, section.close - 1) or ""
end

local function strip_comment(line)
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

function M.key_values(body)
	local result = {}
	for line in tostring(body or ""):gmatch("[^\n]+") do
		line = strip_comment(line)
		local key, value = line:match("^%s*([%w_.-]+)%s*:%s*(.-)%s*$")
		if key and value then result[key] = M.unquote(value) end
	end
	return result
end

function M.ensure_key(body, key, value)
	local values = M.key_values(body)
	if values[key] ~= nil then return body end
	local trailing = (body or ""):match("(%s*)$") or ""
	local head = (body or ""):sub(1, #(body or "") - #trailing)
	local separator = head ~= "" and "\n" or ""
	return head .. separator .. "\t" .. key .. ": " .. M.dae_quote(value) .. trailing
end

function M.named_entries(body)
	local result = {}
	for line in tostring(body or ""):gmatch("[^\n]+") do
		line = strip_comment(line)
		local key, value = line:match("^%s*([%w_.-]+)%s*:%s*(.-)%s*$")
		if key and value then result[#result + 1] = { name = key, value = M.unquote(value) } end
	end
	return result
end

function M.replace_section(content, name, block)
	local parsed, err = M.parse(content)
	if not parsed then return nil, err end
	local list = parsed.byName[name] or {}
	if #list > 1 then return nil, "duplicate " .. name .. " section" end
	if #list == 0 then
		local prefix = content:gsub("%s*$", "")
		return prefix .. (prefix ~= "" and "\n\n" or "") .. block .. "\n", nil
	end
	local section = list[1]
	return content:sub(1, section.start - 1) .. block .. content:sub(section.finish + 1), nil
end

-- Replace a nested section while keeping the rest of the parent section and
-- all unknown configuration intact.  Blocks passed here include their parent
-- indentation (for example, "\tclash_api { ... }").
function M.replace_nested_section(content, outer_name, nested_name, block)
	local outer, err = M.section(content, outer_name)
	if err then return nil, err end
	if not outer then
		local outer_block = outer_name .. " {\n" .. block .. "\n}"
		return M.replace_section(content, outer_name, outer_block)
	end
	local body = M.section_body(content, outer)
	local nested, nested_err = M.section(body, nested_name)
	if nested_err then return nil, nested_err end
	local updated
	if nested then
		updated = body:sub(1, nested.start - 1) .. block .. body:sub(nested.finish + 1)
	else
		local trailing = body:match("(%s*)$") or ""
		local head = body:sub(1, #body - #trailing)
		updated = head .. (head ~= "" and "\n\n" or "\n") .. block .. trailing
	end
	local outer_block = outer_name .. " {" .. updated .. "}"
	return content:sub(1, outer.start - 1) .. outer_block .. content:sub(outer.finish + 1), nil
end

function M.replace_managed(content, blocks, marker)
	local parsed, err = M.parse(content)
	if not parsed then return nil, err end
	local managed = { global = true, group = true, routing = true, dns = true }
	for name in pairs(managed) do
		if #(parsed.byName[name] or {}) > 1 then return nil, "duplicate " .. name .. " section" end
	end
	local kept, cursor = {}, 1
	for _, section in ipairs(parsed.sections) do
		if managed[section.name] then
			kept[#kept + 1] = content:sub(cursor, section.start - 1)
			cursor = section.finish + 1
		end
	end
	kept[#kept + 1] = content:sub(cursor)
	local preserved = table.concat(kept)
	preserved = preserved:gsub("[^\n]*luci%-app%-honk%s+managed:[^\n]*\n?", "")
	preserved = M.trim(preserved)
	local result = marker .. "\n" .. table.concat(blocks, "\n\n")
	if preserved ~= "" then result = result .. "\n\n" .. preserved end
	return result .. "\n", nil
end

function M.file_revision(path)
	local pipe = io.popen("sha256sum " .. M.shell_quote(path or M.CONFIG) .. " 2>/dev/null")
	if not pipe then return "" end
	local output = pipe:read("*l") or ""
	pipe:close()
	return output:match("^([0-9a-fA-F]+)") or ""
end

function M.revision(content)
	local path = "/tmp/honk-luci-revision-" .. tostring(nixio.getpid and nixio.getpid() or math.random(1000, 9999))
	if not fs.writefile(path, content or "") then return "" end
	fs.chmod(path, 600)
	local result = M.file_revision(path)
	fs.remove(path)
	return result
end

function M.redact(value)
	value = tostring(value or "")
	value = value:gsub("([%w+%.%-]+://)[^@%s]+@", "%1***@")
	value = value:gsub("([?&])([%w_%-]+)=([^&#%s]+)", function(prefix, key, secret)
		local lower = key:lower()
		if lower == "token" or lower == "key" or lower == "password" or lower == "secret" or lower == "auth" then
			return prefix .. key .. "=***"
		end
		return prefix .. key .. "=" .. secret
	end)
	value = value:gsub("([Pp]assword%s*[:=]%s*)[^%s,]+", "%1***")
	value = value:gsub("([Ss]ecret%s*[:=]%s*)[^%s,]+", "%1***")
	value = value:gsub("([Tt]oken%s*[:=]%s*)[^%s,]+", "%1***")
	return value
end

function M.validate(content)
	if type(content) ~= "string" then return false, "configuration must be text", nil end
	if #content > M.MAX_BYTES then return false, "configuration exceeds 1 MiB", nil end
	local path = "/tmp/honk-luci-validate-" .. tostring(nixio.getpid and nixio.getpid() or math.random(1000, 9999))
	if not fs.writefile(path, content) then return false, "temporary configuration could not be written", nil end
	fs.chmod(path, 600)
	local command = M.shell_quote(M.HONK_TOOL) .. " validate --config " .. M.shell_quote(path) .. " --json 2>&1; printf '\n__HONK_EXIT:%s' \"$?\""
	local pipe = io.popen(command)
	local output = pipe and (pipe:read("*a") or "") or ""
	if pipe then pipe:close() end
	fs.remove(path)
	local code = tonumber(output:match("__HONK_EXIT:(%d+)%s*$"))
	local detail = output:gsub("%s*__HONK_EXIT:%d+%s*$", "")
	local decoded = jsonc.parse(detail)
	return code == 0, M.redact(M.trim(detail)), decoded
end

function M.write_atomic(content, path)
	path = path or M.CONFIG
	local temp = path .. ".tmp." .. tostring(nixio.getpid and nixio.getpid() or math.random(1000, 9999))
	if not fs.writefile(temp, content) then return nil, "temporary configuration could not be written" end
	fs.chmod(temp, 600)
	if not fs.rename(temp, path) then
		fs.remove(temp)
		return nil, "configuration could not be replaced"
	end
	return true, nil
end

return M
