module("luci.controller.honk", package.seeall)

local http = require "luci.http"
local jsonc = require "luci.jsonc"
local nixio = require "nixio"

local API_NAMES = {
	"state", "preview", "apply", "service", "sources", "advanced", "validate_advanced",
	"apply_advanced", "refresh_subscription", "subscription_cache", "delete_subscription_cache", "delay", "connectivity", "diagnostics", "logs", "clear_logs",
	"toggle_clash_api", "default_config", "reset_config",
	"network_interfaces", "apply_interfaces",
}

function index()
	if nixio.fs.access("/usr/share/ucode/luci/dispatcher.uc") then return end
	if not nixio.fs.access("/etc/config/honk") then return end
	local page = entry({ "admin", "services", "honk" }, firstchild(), _("Honk"), 50)
	page.dependent = true
	page.acl_depends = { "luci-app-honk" }
	entry({ "admin", "services", "honk", "dashboard" }, template("honk/dashboard")).leaf = true
	local api = entry({ "admin", "services", "honk", "api" }, firstchild())
	api.leaf = false
	for _, name in ipairs(API_NAMES) do
		entry({ "admin", "services", "honk", "api", name }, call("api_" .. name)).leaf = true
	end
end

local function respond(payload, status)
	if status then http.status(status) end
	http.header("Cache-Control", "no-store")
	http.prepare_content("application/json")
	http.write_json(payload)
end

local function request_body()
	local raw = http.content() or ""
	if #raw > 1048576 then return nil, "request body is too large", 413 end
	if raw == "" then return {}, nil, nil end
	local decoded = jsonc.parse(raw)
	if type(decoded) ~= "table" then return nil, "invalid JSON request body", 400 end
	return decoded, nil, nil
end

local function post_guard()
	if http.getenv("REQUEST_METHOD") ~= "POST" then
		respond({ ok = false, error = { code = "METHOD_NOT_ALLOWED", message = "POST required" } }, 405)
		return false
	end
	local dispatcher = require "luci.dispatcher"
	local context = dispatcher.context or {}
	local session = context.authsession
	local expected = context.authtoken
	local acl = context.acl
	if type(acl) == "table" and acl["luci-app-honk"] == false then
		respond({ ok = false, error = { code = "ACL_REQUIRED", message = "required LuCI ACL is missing" } }, 403)
		return false
	end
	local token = http.getenv("HTTP_X_CSRF_TOKEN") or http.formvalue("csrf_token") or http.formvalue("token")
	if not session or session == "" or not expected or expected == "" or not token or token ~= expected then
		respond({ ok = false, error = { code = "CSRF_OR_AUTH_REQUIRED", message = "authenticated session and CSRF token required" } }, 403)
		return false
	end
	return true
end

local function mutate(method)
	if not post_guard() then return end
	local data, err, status = request_body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.service")[method](data)
	respond(result, code)
end

function api_state() respond(require("luci.model.service").state(false)) end
function api_advanced() respond(require("luci.model.service").advanced()) end
function api_default_config() respond(require("luci.model.service").default_config()) end
function api_diagnostics() respond(require("luci.model.service").diagnostics()) end
function api_logs() respond(require("luci.model.service").logs()) end
function api_clear_logs() mutate("clear_logs") end
function api_preview() mutate("preview") end
function api_apply() mutate("apply") end
function api_sources() mutate("mutate_source") end
function api_apply_advanced() mutate("apply_advanced") end
function api_toggle_clash_api() mutate("toggle_clash_api") end
function api_refresh_subscription() mutate("refresh_subscription") end
function api_subscription_cache() mutate("subscription_cache") end
function api_delete_subscription_cache() mutate("delete_subscription_cache") end
function api_delay() mutate("delay") end
function api_connectivity() mutate("connectivity") end
function api_reset_config() mutate("reset_config") end
function api_network_interfaces() respond(require("luci.model.service").network_interfaces()) end
function api_apply_interfaces() mutate("apply_interfaces") end

function api_validate_advanced()
	if not post_guard() then return end
	local data, err, status = request_body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.service").validate_advanced(data.config)
	respond(result, code)
end

function api_service()
	if not post_guard() then return end
	local data, err, status = request_body()
	if not data then respond({ ok = false, error = { code = "INVALID_REQUEST", message = err } }, status); return end
	local result, code = require("luci.model.service").service(data.action)
	respond(result, code)
end
