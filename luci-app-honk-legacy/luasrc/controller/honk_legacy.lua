module("luci.controller.honk_legacy", package.seeall)

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

	local page = entry({"admin", "services", "honk-legacy"}, firstchild(), _("Honk Legacy"), 60)
	page.dependent = true
	page.acl_depends = { "luci-app-honk-legacy" }
	entry({"admin", "services", "honk-legacy", "dashboard"}, template("honk_legacy/dashboard")).leaf = true
	entry({"admin", "services", "honk-legacy", "config"}, call("redirect_config")).leaf = true

	local api = {"admin", "services", "honk-legacy", "api"}
	entry(api, firstchild()).leaf = false
	for _, name in ipairs({"dashboard", "dashboard_prepare", "state", "validate", "save", "apply", "service", "logs", "traffic", "model", "runtime_nodes", "model_parse", "model_preview", "model_apply", "node_parse", "node_test", "network_discovery", "quick_state", "quick_preview", "quick_apply", "geo_repair", "transaction_status"}) do
		entry({"admin", "services", "honk-legacy", "api", name}, call("api_" .. name)).leaf = true
	end
end

function redirect_config()
	http.redirect(require("luci.dispatcher").build_url("admin", "services", "honk-legacy") .. "#/settings")
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

local function require_authenticated_session_acl_post_csrf()
	if not post() then return false end
	local dispatcher = require "luci.dispatcher"
	local context = dispatcher.context or {}
	local expected = context.authsession
	local acl = context.acl
	if type(acl) == "table" then
		if acl["luci-app-honk-legacy"] == false or acl["luci-app-honk-legacy.quick-setup"] == false then
			respond({ ok = false, error = { code = "ACL_REQUIRED", message = "required LuCI ACL is missing" } }, 403)
			return false
		end
	end
	local token = http.getenv("HTTP_X_CSRF_TOKEN") or http.formvalue("csrf_token") or http.formvalue("token")
	if not expected or expected == "" or not token or token ~= expected then
		respond({ ok = false, error = { code = "CSRF_OR_AUTH_REQUIRED", message = "authenticated session and CSRF token required" } }, 403)
		return false
	end
	return true
end

local function mutation_guard()
	return require_authenticated_session_acl_post_csrf()
end

function api_dashboard()
	respond(require("luci.model.honk_legacy_api").dashboard())
end

function api_dashboard_prepare()
	if not mutation_guard() then return end
	local result, code = require("luci.model.honk_legacy_api").dashboard_prepare()
	respond(result, code)
end

function api_state()
	respond(require("luci.model.honk_legacy_api").state())
end

function api_validate()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_legacy_api").validate(data.config)
	respond(result, code)
end

function api_save()
	if not mutation_guard() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_legacy_api").save(data.config, data.revision, false)
	respond(result, code)
end

function api_apply()
	if not mutation_guard() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_legacy_api").save(data.config, data.revision, true)
	respond(result, code)
end

function api_service()
	if not mutation_guard() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_legacy_api").service(data.action)
	respond(result, code)
end

function api_logs()
	respond(require("luci.model.honk_legacy_api").logs())
end

function api_traffic()
	respond(require("luci.model.honk_legacy_api").traffic())
end

function api_model()
	respond(require("luci.model.honk_legacy_api").model())
end

function api_runtime_nodes()
	respond(require("luci.model.honk_legacy_api").runtime_nodes())
end

function api_model_parse()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	respond(require("luci.model.honk_legacy_api").model(data.config))
end

function api_model_preview()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_legacy_api").preview(data.config)
	respond(result, code)
end

function api_model_apply()
	if not mutation_guard() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_legacy_api").save(data.config, data.revision, true)
	respond(result, code)
end

function api_node_parse()
	if not post() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_legacy_api").parse_node(data.link)
	respond(result, code)
end

function api_node_test()
	if not mutation_guard() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_legacy_api").test_node(data.link, data)
	respond(result, code)
end

function api_network_discovery()
	respond(require("luci.model.honk_legacy_api").network_discovery())
end

function api_quick_state()
	respond(require("luci.model.honk_legacy_api").quick_state())
end

function api_quick_preview()
	if not mutation_guard() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local dispatcher = require "luci.dispatcher"
	data.sessionId = data.sessionId or (dispatcher.context and dispatcher.context.authsession)
	local result, code = require("luci.model.honk_legacy_api").quick_preview(data)
	respond(result, code)
end

function api_quick_apply()
	if not mutation_guard() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local dispatcher = require "luci.dispatcher"
	data.sessionId = data.sessionId or (dispatcher.context and dispatcher.context.authsession)
	local result, code = require("luci.model.honk_legacy_api").quick_apply(data)
	respond(result, code)
end

function api_geo_repair()
	if not mutation_guard() then return end
	local data, err, status = body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.honk_legacy_api").geo_repair(data.confirm == true)
	respond(result, code)
end

function api_transaction_status()
	respond(require("luci.model.honk_legacy_api").transaction_status())
end
