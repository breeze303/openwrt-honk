module("luci.controller.honk", package.seeall)

local http = require "luci.http"
local nixio = require "nixio"

function index()
	-- Modern LuCI builds the route tree from menu.d JSON.  Keeping the
	-- legacy entries out of that tree avoids replacing the JSON root node.
	if nixio.fs.access("/usr/share/ucode/luci/dispatcher.uc") then
		return
	end
	if not nixio.fs.access("/etc/config/honk") then
		return
	end

	local page = entry({"admin", "services", "honk"}, firstchild(), _("Honk"), 50)
	page.dependent = true
	page.acl_depends = { "luci-app-honk" }
	entry({"admin", "services", "honk", "dashboard"}, template("honk/dashboard")).leaf = true
	entry({"admin", "services", "honk", "config"}, call("redirect_config")).leaf = true

	local api = {"admin", "services", "honk", "api"}
	entry(api, firstchild()).leaf = false
	for _, name in ipairs({"dashboard", "dashboard_prepare", "state", "validate", "save", "apply", "service", "logs", "traffic", "model", "runtime_nodes", "model_parse", "model_preview", "model_apply", "node_parse", "node_test"}) do
		entry({"admin", "services", "honk", "api", name}, call("api_" .. name)).leaf = true
	end
end

function redirect_config()
	http.redirect(require("luci.dispatcher").build_url("admin", "services", "honk") .. "#/settings")
end

local function respond(payload, status)
	if status then http.status(status) end
	http.header("Cache-Control", "no-store")
	http.prepare_content("application/json")
	http.write_json(payload)
end

local function body()
	local raw = http.content() or ""
	if #raw > 1048576 then return nil, "request body is too large", 413 end
	if raw == "" then return {}, nil, nil end
	local value = luci.jsonc.parse(raw)
	if type(value) ~= "table" then return nil, "invalid JSON request body", 400 end
	return value
end

local function post()
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		respond({ ok = false, error = { code = "METHOD_NOT_ALLOWED", message = "POST required" } }, 405)
		return false
	end
	return true
end

function api_dashboard()
	respond(require("luci.model.honk_api").dashboard())
end

function api_dashboard_prepare()
	if not post() then return end
	local result, code = require("luci.model.honk_api").dashboard_prepare()
	respond(result, code)
end

function api_state()
	respond(require("luci.model.honk_api").state())
end

function api_validate()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_api").validate(data.config)
	respond(result, code)
end

function api_save()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_api").save(data.config, data.revision, false)
	respond(result, code)
end

function api_apply()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_api").save(data.config, data.revision, true)
	respond(result, code)
end

function api_service()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_api").service(data.action)
	respond(result, code)
end

function api_logs()
	respond(require("luci.model.honk_api").logs())
end

function api_traffic()
	respond(require("luci.model.honk_api").traffic())
end

function api_model()
	respond(require("luci.model.honk_api").model())
end

function api_runtime_nodes()
	respond(require("luci.model.honk_api").runtime_nodes())
end

function api_model_parse()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	respond(require("luci.model.honk_api").model(data.config))
end

function api_model_preview()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_api").preview(data.config)
	respond(result, code)
end

function api_model_apply()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_api").save(data.config, data.revision, true)
	respond(result, code)
end

function api_node_parse()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_api").parse_node(data.link)
	respond(result, code)
end

function api_node_test()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_api").test_node(data.link, data)
	respond(result, code)
end
