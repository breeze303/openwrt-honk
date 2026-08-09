local config = require "luci.model.config"

local M = {}

M.DEFAULT_DIRECT = "udp://223.5.5.5:53"
M.DEFAULT_PROXY = "https://cloudflare-dns.com/dns-query"
M.DEFAULT_BIND = "tcp+udp://127.0.0.1:1053"

local function upstream_value(body, name)
	local parsed = config.parse(body)
	if not parsed then return nil end
	local upstream = (parsed.byName.upstream or {})[1]
	if not upstream then return nil end
	for _, entry in ipairs(config.named_entries(config.section_body(body, upstream))) do
		if entry.name == name then
			local value = entry.value:gsub("%s*%-%>%s*[%w_.-]+%s*$", "")
			return config.unquote(config.trim(value))
		end
	end
	return nil
end

function M.current(content)
	local section = config.section(content, "dns")
	local body = section and config.section_body(content, section) or ""
	local values = config.key_values(body)
	return {
		bind = values.bind or M.DEFAULT_BIND,
		direct = upstream_value(body, "direct-dns") or M.DEFAULT_DIRECT,
		proxy = upstream_value(body, "proxy-dns") or M.DEFAULT_PROXY,
	}
end

local function valid_uri(value)
	return type(value) == "string" and #value <= 512 and value:match("^[%w+.-]+://[^%s]+$") ~= nil
end

function M.render(mode, options)
	options = type(options) == "table" and options or {}
	local bind = config.trim(options.bind or M.DEFAULT_BIND)
	local direct = config.trim(options.direct or M.DEFAULT_DIRECT)
	local proxy = config.trim(options.proxy or M.DEFAULT_PROXY)
	if not valid_uri(bind) then return nil, "DNS_BIND_INVALID" end
	if not valid_uri(direct) then return nil, "DIRECT_DNS_INVALID" end
	if not valid_uri(proxy) then return nil, "PROXY_DNS_INVALID" end
	local rules = {}
	if mode == "china-direct" then
		rules = { "\t\t\tqname(geosite: cn) -> direct-dns", "\t\t\tfallback: proxy-dns" }
	elseif mode == "gfwlist" then
		rules = { "\t\t\tqname(geosite: gfw) -> proxy-dns", "\t\t\tfallback: direct-dns" }
	elseif mode == "china-proxy" then
		rules = { "\t\t\tqname(geosite: cn) -> proxy-dns", "\t\t\tfallback: direct-dns" }
	elseif mode == "global" then
		rules = { "\t\t\tfallback: proxy-dns" }
	else
		return nil, "MODE_UNKNOWN"
	end
	local lines = {
		"dns {",
		"\tbind: " .. config.dae_quote(bind),
		"\tupstream {",
		"\t\tdirect-dns: " .. config.dae_quote(direct),
		"\t\tproxy-dns: " .. config.dae_quote(proxy) .. " -> honk-proxy",
		"\t}",
		"\trouting {",
		"\t\trequest {",
	}
	for _, line in ipairs(rules) do lines[#lines + 1] = line end
	lines[#lines + 1] = "\t\t}"
	lines[#lines + 1] = "\t\tresponse {"
	lines[#lines + 1] = "\t\t\tfallback: accept"
	lines[#lines + 1] = "\t\t}"
	lines[#lines + 1] = "\t}"
	lines[#lines + 1] = "}"
	return table.concat(lines, "\n"), nil, rules
end

return M
