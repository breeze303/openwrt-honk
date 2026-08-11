// SPDX-License-Identifier: Apache-2.0
'use strict';

import { access, chmod, popen, readfile, stat, unlink, writefile } from 'fs';
import { cursor } from 'uci';
import * as config from 'luci.honk.config';
import * as dns from 'luci.honk.dns';
import * as mode from 'luci.honk.mode';
import * as network from 'luci.honk.network';
import * as node from 'luci.honk.node';
import * as subscription from 'luci.honk.subscription';

const STATE = getenv('HONK_LUCI_STATE_PATH') || `${config.RUN_DIR}/luci-state.json`;
const INIT = '/etc/init.d/honk';
const WORKER = '/usr/libexec/honk/quick-transaction-worker';
const GEO_DIR = '/usr/share/v2ray';
const LOG_FILE = getenv('HONK_LOG_PATH') || '/tmp/honk/honk.log';
const LOG_LEVELS = { trace: true, debug: true, info: true, warn: true, error: true };
const DEFAULT_WAN_DNS_SERVERS = '119.29.29.29 223.5.5.5';
const SERVICE_STATE_TIMEOUT = 15;

const ERROR_MESSAGES = {
	MODE_UNKNOWN: 'unknown routing mode',
	PROXY_SOURCE_INVALID: 'proxy source selection is malformed',
	PROXY_SOURCE_REQUIRED: 'select at least one node or subscription',
	PROXY_SOURCE_LIMIT: 'too many proxy sources were selected',
	DIRECT_DNS_INVALID: 'direct DNS upstream is invalid',
	PROXY_DNS_INVALID: 'proxy DNS upstream is invalid',
	DEVICE_RULES_INVALID: 'device rule list is invalid',
	DEVICE_RULE_INVALID: 'device rule is invalid',
	DEVICE_IP_INVALID: 'device IP or CIDR is invalid',
	DEVICE_MAC_INVALID: 'device MAC address is invalid',
	DEVICE_RULE_DUPLICATE: 'duplicate device rule',
	ADVANCED_TAKEOVER_REQUIRED: 'custom routing is active; confirm Advanced configuration takeover',
	REVISION_REQUIRED: 'configuration revision is required',
	REVISION_CONFLICT: 'configuration changed; reload before applying',
	CONFIG_INVALID: 'candidate configuration failed validation',
	GEO_DATA_MISSING: 'required Geo data is missing from /usr/share/v2ray',
	WRITE_FAILED: 'configuration replacement failed',
	SERVICE_FAILED: 'service did not become healthy',
	ROLLBACK: 'apply failed and the previous configuration was restored',
	ROLLBACK_DEGRADED: 'apply failed and service recovery needs attention',
	LOCK_FAILED: 'configuration operation is already in progress',
	SOURCE_ACTION_INVALID: 'source action is invalid',
	SUBSCRIPTION_REFRESH_FAILED: 'subscription refresh request failed',
	NODE_MISSING: 'node is not available in the running catalog',
	CLASH_API_UNAVAILABLE: 'Clash API is unavailable',
	CLASH_API_INVALID: 'Clash API setting is invalid',
	DELAY_API_INVALID: 'delay response is invalid',
	NODE_DELAY_FAILED: 'node delay test failed',
	CONNECTIVITY_TARGET_INVALID: 'connectivity target is invalid',
	DEFAULT_CONFIG_MISSING: 'default configuration template is unavailable',
	INTERFACE_AMBIGUOUS: 'network interfaces are ambiguous; choose LAN and WAN explicitly',
	INTERFACE_NOT_AVAILABLE: 'selected network interface is no longer available',
	INTERFACE_SAME: 'LAN and WAN must use different devices',
	DIAL_MODE_INVALID: 'dial mode is invalid',
	LOG_LEVEL_INVALID: 'log level is invalid',
	LOG_CLEAR_FAILED: 'Honk log could not be cleared',
	LOCAL_DNS_INVALID: 'local DNS settings are invalid',
	LOCAL_DNS_SAVE_FAILED: 'local DNS settings could not be saved',
	NETWORK_DISCOVERY_FAILED: 'network interface discovery failed',
	TRANSACTION_WORKER_UNAVAILABLE: 'configuration transaction worker is unavailable',
};

const GEO_ASSETS = {
	geosite: { file: 'geosite.dat', package: 'v2ray-geosite' },
	geoip: { file: 'geoip.dat', package: 'v2ray-geoip' },
};

const CONNECTIVITY_TARGETS = [
	{ id: 'aliyun', url: 'https://www.aliyun.com', route: 'direct' },
	{ id: 'google', url: 'https://www.google.com/generate_204', route: 'honk-proxy' },
	{ id: 'github', url: 'https://github.com', route: 'honk-proxy' },
	{ id: 'youtube', url: 'https://www.youtube.com', route: 'honk-proxy' },
];

function error_result(code, detail, extra) {
	const base = match(sprintf('%s', code || 'INTERNAL_ERROR'), /^([^:]+)/)?.[1] || 'INTERNAL_ERROR';
	return config.result_error(base, detail || ERROR_MESSAGES[base] || code || 'operation failed', extra);
}

function running() {
	return system('/bin/pidof honk-core >/dev/null 2>&1') === 0;
}

function wait_for_running(expected) {
	const deadline = time() + SERVICE_STATE_TIMEOUT;
	while (true) {
		if (running() === expected) return true;
		if (time() >= deadline) return false;
		system('/bin/sleep 1 >/dev/null 2>&1');
	}
}

function read_state() {
	try {
		const value = json(config.read(STATE));
		return type(value) === 'object' ? value : { stage: 'none' };
	} catch (e) {
		return { stage: 'none' };
	}
}

function iso_now() {
	const fd = popen('/bin/date -u +%Y-%m-%dT%H:%M:%SZ', 'r');
	const value = trim(fd?.read?.('all') || '');
	fd?.close();
	return value || null;
}

function write_state(value) {
	if (!config.ensure_run_dir()) return false;
	value.updatedAt = iso_now();
	if (!writefile(STATE, sprintf('%J', value))) return false;
	chmod(STATE, 0600);
	return true;
}

function resolver_nameservers(path) {
	let servers = [], seen = {};
	for (let line in split(readfile(path) || '', /\r?\n/)) {
		const server = match(line, /^\s*nameserver\s+([^[:space:]#]+)/)?.[1];
		if (server && !seen[server]) { seen[server] = true; push(servers, server); }
	}
	return length(servers) ? join(' ', servers) : DEFAULT_WAN_DNS_SERVERS;
}

function read_local_dns_values() {
	const uci = cursor();
	const value = uci.get('honk', 'main', 'dnsmasq_forwarding');
	const legacy = uci.get('honk', 'main', 'proxy_local_dns');
	const servers = uci.get('honk', 'main', 'local_dns_servers');
	uci.unload();
	return { dnsmasq_forwarding: value, proxy_local_dns: legacy, local_dns_servers: servers };
}

function local_dns_settings() {
	const configured = read_local_dns_values();
	let state;
	try { state = json(readfile(`${config.RUN_DIR}/dnsmasq-forwarding.json`) || ''); } catch (e) { state = {}; }
	if (type(state) !== 'object') state = {};
	const option = configured.dnsmasq_forwarding ?? configured.proxy_local_dns;
	return {
		enabled: option !== '0',
		servers: resolver_nameservers('/etc/resolv.conf'),
		active: state.active === true,
		owned: state.active === true && state.schemaVersion === 'honk.dnsmasq.v1',
		path: '/etc/resolv.conf',
		endpoint: state.endpoint || '127.0.0.1#1053',
		dnsmasq: state,
	};
}

function local_dns_input(input) {
	let value = input.dnsmasqForwarding;
	if (value == null) value = input.proxyLocalDns;
	if (value != null && !config.is_bool(value)) return [null, 'LOCAL_DNS_INVALID'];
	return [{ enabled: value !== false }, null];
}

function restore_local_dns_values(previous) {
	const uci = cursor();
	for (let key in [ 'dnsmasq_forwarding', 'proxy_local_dns', 'local_dns_servers' ]) {
		if (previous[key] == null) uci.delete('honk', 'main', key);
		else uci.set('honk', 'main', key, previous[key]);
	}
	const saved = uci.save('honk');
	const committed = saved && uci.commit('honk');
	uci.unload();
	return !!committed;
}

function write_local_dns_settings(settings) {
	const uci = cursor();
	uci.set('honk', 'main', 'dnsmasq_forwarding', settings.enabled ? '1' : '0');
	uci.delete('honk', 'main', 'proxy_local_dns');
	uci.delete('honk', 'main', 'local_dns_servers');
	const saved = uci.save('honk');
	const committed = saved && uci.commit('honk');
	uci.unload();
	return !!committed;
}

function geo_check() {
	let assets = {}, valid = true;
	for (let kind, spec in GEO_ASSETS) {
		const path = `${GEO_DIR}/${spec.file}`;
		const file = stat(path);
		const present = file?.type === 'file' && (file?.size || 0) > 0;
		assets[kind] = { kind, path, package: spec.package, status: present ? 'PRESENT' : 'MISSING', size: file?.size || 0, ok: present };
		valid = valid && present;
	}
	return [valid, { ok: valid, directory: GEO_DIR, provider: 'openwrt-v2ray-geodata', assets }];
}

function diff_counts(before, after) {
	const old = split(`${before}\n`, '\n');
	const next = split(`${after}\n`, '\n');
	let additions = 0, removals = 0;
	for (let index = 0; index < (length(old) > length(next) ? length(old) : length(next)); index++) {
		if (old[index] === next[index]) continue;
		if (old[index] != null) removals++;
		if (next[index] != null) additions++;
	}
	return [additions, removals];
}

function compile(input) {
	const content = config.read();
	const compiled = mode.compile(content, input);
	return [compiled[0], compiled[1], content];
}

function clash_api_status(content, include_secret) {
	const experimental = config.section(content, 'experimental');
	if (!experimental[0]) return { enabled: false, controller: '', port: null, secretConfigured: false, browserAccessible: false, secret: include_secret ? '' : null };
	const body = config.section_body(content, experimental[0]);
	const clash = config.section(body, 'clash_api');
	if (!clash[0]) return { enabled: false, controller: '', port: null, secretConfigured: false, browserAccessible: false, secret: include_secret ? '' : null };
	const values = config.key_values(config.section_body(body, clash[0]));
	const controller = config.trim_value(values.external_controller);
	const authority = match(controller, /^https?:\/\/([^/]+)/)?.[1] || controller;
	let parsed = match(authority, /^\[([^\]]+)\]:([0-9]+)$/) || match(authority, /^(.*):([0-9]+)$/);
	let host = config.trim_value(parsed?.[1]);
	let port = int(parsed?.[2]);
	if (port == null || port < 1 || port > 65535) port = null;
	host = lc(host);
	const browser_accessible = port != null && host && !(host in { '127.0.0.1': true, localhost: true, '::1': true });
	let result = { enabled: !!controller && port != null, controller, port, secretConfigured: !!config.trim_value(values.secret), browserAccessible: !!browser_accessible };
	if (include_secret) result.secret = config.trim_value(values.secret);
	return result;
}

function random_secret() {
	const bytes = readfile('/dev/urandom', 32);
	if (type(bytes) !== 'string' || length(bytes) !== 32) return null;
	let result = '';
	for (let index = 0; index < length(bytes); index++) result += sprintf('%02x', ord(bytes, index));
	return result;
}

function replace_body_key(body, key, value) {
	let lines = split(body || '', '\n'), changed = false;
	for (let index = 0; index < length(lines); index++) {
		const found = match(lines[index], /^(\s*)([A-Za-z0-9_.-]+)(\s*:\s*)[^\n]*$/);
		if (!found || found[2] !== key || changed) continue;
		lines[index] = `${found[1]}${key}${found[3]}${value}`;
		changed = true;
	}
	if (changed) return join('\n', lines);
	const trailing = match(body || '', /(\s*)$/)?.[1] || '';
	const head = substr(body || '', 0, length(body || '') - length(trailing));
	return `${head}\n\t\t${key}: ${value}${trailing || '\n\t'}`;
}

function clash_api_candidate(content, enabled) {
	let desired_controller = clash_api_status(content, true).controller;
	if (enabled && !desired_controller) desired_controller = '127.0.0.1:9090';
	if (!enabled) desired_controller = '';
	const experimental = config.section(content, 'experimental');
	if (!experimental[0]) {
		const block = join('\n', [ '\tclash_api {', `\t\texternal_controller: ${config.daequote(desired_controller)}`, "\t\texternal_ui: '/www/luci-static/resources/honk/app'", "\t\tsecret: ''", "\t\tdefault_mode: 'Rule'", '\t}' ]);
		return config.replace_nested_section(content, 'experimental', 'clash_api', block);
	}
	const body = config.section_body(content, experimental[0]);
	const clash = config.section(body, 'clash_api');
	const block = clash[0] ? `\tclash_api {${replace_body_key(config.section_body(body, clash[0]), 'external_controller', config.daequote(desired_controller))}}` : `\tclash_api {\n\t\texternal_controller: ${config.daequote(desired_controller)}\n\t}`;
	return config.replace_nested_section(content, 'experimental', 'clash_api', block);
}

function runtime_api_candidate(content, status, secret) {
	const controller = `0.0.0.0:${status.port || 9090}`;
	const experimental = config.section(content, 'experimental');
	if (!experimental[0]) {
		const block = join('\n', [ '\tclash_api {', `\t\texternal_controller: ${config.daequote(controller)}`, "\t\texternal_ui: '/www/luci-static/resources/honk/app'", `\t\tsecret: ${config.daequote(secret)}`, "\t\tdefault_mode: 'Rule'", '\t}' ]);
		return config.replace_nested_section(content, 'experimental', 'clash_api', block);
	}
	const body = config.section_body(content, experimental[0]);
	const clash = config.section(body, 'clash_api');
	let block;
	if (clash[0]) {
		let clash_body = config.section_body(body, clash[0]);
		clash_body = replace_body_key(clash_body, 'external_controller', config.daequote(controller));
		clash_body = replace_body_key(clash_body, 'secret', config.daequote(secret));
		block = `\tclash_api {${clash_body}}`;
	}
	else block = join('\n', [ '\tclash_api {', `\t\texternal_controller: ${config.daequote(controller)}`, "\t\texternal_ui: '/www/luci-static/resources/honk/app'", `\t\tsecret: ${config.daequote(secret)}`, "\t\tdefault_mode: 'Rule'", '\t}' ]);
	return config.replace_nested_section(content, 'experimental', 'clash_api', block);
}

function worker_apply(path, expected_revision, nonce, policy) {
	if (!access(WORKER)) return [null, 'TRANSACTION_WORKER_UNAVAILABLE'];
	const command = `${config.shellquote(WORKER)} --apply ${config.shellquote(path)} ${config.shellquote(expected_revision)} ${config.shellquote(nonce)} ${config.shellquote(policy)}`;
	const fd = popen(command, 'r');
	const output = fd?.read?.('all') || '';
	const code = fd ? fd.close() : 127;
	let result = null;
	try { result = json(trim(output)); } catch (e) { /* retain code below */ }
	if (type(result) !== 'object') return [null, code === 0 ? 'WRITE_FAILED' : 'SERVICE_FAILED'];
	return [result, null];
}

export function apply_content(candidate, expected_revision, metadata, policy) {
	if (type(expected_revision) !== 'string' || !match(expected_revision, /^[a-fA-F0-9]{64}$/)) return error_result('REVISION_REQUIRED');
	if (type(candidate) !== 'string' || length(candidate) > config.MAX_BYTES) return error_result('CONFIG_INVALID');
	const validation = config.validate(candidate);
	if (!validation[0]) return error_result('CONFIG_INVALID', validation[1], { validation: validation[2] });
	if (config.file_revision() !== expected_revision) return error_result('REVISION_CONFLICT');
	const staged = config.write_candidate(candidate, 'apply');
	if (!staged[0]) return error_result(staged[1] || 'WRITE_FAILED');
	let previous_local_dns = null;
	if (metadata?.localDns) {
		previous_local_dns = read_local_dns_values();
		if (!write_local_dns_settings(metadata.localDns)) { unlink(staged[0]); return error_result('LOCAL_DNS_SAVE_FAILED'); }
	}
	const nonce = substr(config.revision(candidate), 0, 24) || sprintf('%x', time());
	write_state({ stage: 'submitted', previousRevision: expected_revision, metadata: metadata || {} });
	const transaction = worker_apply(staged[0], expected_revision, nonce, policy || 'start');
	unlink(staged[0]);
	if (!transaction[0]) {
		if (previous_local_dns) restore_local_dns_values(previous_local_dns);
		write_state({ stage: 'write-failed', recentError: transaction[1], rollback: false, metadata: metadata || {} });
		return error_result(transaction[1]);
	}
	const result = transaction[0];
	if (result.ok !== true) {
		if (previous_local_dns) restore_local_dns_values(previous_local_dns);
		write_state({ stage: result.stage || 'rollback', activeRevision: config.file_revision(), recentError: result.error?.message, rollback: true, metadata: metadata || {} });
		return result;
	}
	const active = config.file_revision();
	let selection_synchronized = null;
	if (metadata?.type === 'mode' && type(metadata.selected) === 'object' && length(metadata.selected.nodes || []) === 1 && !length(metadata.selected.subscriptions || []))
		selection_synchronized = node.set_group_selection(candidate, 'honk-proxy', metadata.selected.nodes[0])[0];
	const action = result.action || (policy === 'preserve' && !running() ? 'none' : 'start');
	write_state({ stage: 'committed', activeRevision: active, action, rollback: false, metadata: metadata || {} });
	return { ok: true, applied: true, action, revision: active, running: running(), rollback: false, selectionSynchronized: selection_synchronized };
}

export function preview(input) {
	const compiled = compile(input);
	if (!compiled[0]) return error_result(compiled[1]);
	const geo = geo_check();
	if (!geo[0]) return error_result('GEO_DATA_MISSING', null, { geo: geo[1] });
	const validation = config.validate(compiled[0].candidate);
	if (!validation[0]) return error_result('CONFIG_INVALID', validation[1], { validation: validation[2] });
	const counts = diff_counts(compiled[2], compiled[0].candidate);
	return {
		ok: true,
		mode: compiled[0].mode,
		previousMode: compiled[0].previousMode,
		requiresTakeover: compiled[0].requiresTakeover,
		expectedRevision: config.file_revision(),
		candidateRevision: config.revision(compiled[0].candidate),
		selected: compiled[0].selected,
		deviceRules: compiled[0].deviceRules,
		routing: compiled[0].routingLines,
		dns: compiled[0].dnsRules,
		changes: { additions: counts[0], removals: counts[1] },
		geo: geo[1],
	};
}

export function default_config() {
	const content = config.read_default();
	if (!content) return error_result('DEFAULT_CONFIG_MISSING');
	return { ok: true, content, revision: config.file_revision(), templateRevision: config.revision(content) };
}

export function reset_config(input) {
	if (type(input) !== 'object') return error_result('REVISION_REQUIRED');
	const content = config.read_default();
	if (!content) return error_result('DEFAULT_CONFIG_MISSING');
	return apply_content(content, input.expectedRevision, { type: 'reset-default' }, 'start');
}

export function apply(input) {
	const compiled = compile(input);
	if (!compiled[0]) return error_result(compiled[1]);
	if (compiled[0].requiresTakeover && input.takeover !== true) return error_result('ADVANCED_TAKEOVER_REQUIRED', null, { requiresTakeover: true });
	const geo = geo_check();
	if (!geo[0]) return error_result('GEO_DATA_MISSING', null, { geo: geo[1] });
	return apply_content(compiled[0].candidate, input.expectedRevision, { type: 'mode', mode: compiled[0].mode, selected: compiled[0].selected }, 'start');
}

export function state(include_config) {
	const content = config.read();
	const current_mode = mode.detect(content);
	const last = read_state();
	const local_catalog = node.catalog(content);
	const revision = config.file_revision();
	const is_running = running();
	const runtime = node.runtime_catalog(content);
	if (runtime.available) subscription.capture_runtime(local_catalog, runtime.nodes);
	const cached_nodes = subscription.catalog_nodes(local_catalog);
	local_catalog.subscriptionNodes = runtime.available ? runtime.nodes : cached_nodes;
	local_catalog.cachedNodes = cached_nodes;
	local_catalog.runtimeAvailable = runtime.available;
	local_catalog.runtimeConfigured = runtime.configured;
	local_catalog.cacheAvailable = length(cached_nodes) > 0;
	let result = {
		ok: true,
		running: is_running,
		revision,
		activeRevision: is_running ? (last.activeRevision || revision) : (last.activeRevision || ''),
		dirty: is_running && last.activeRevision != null && last.activeRevision !== revision,
		mode: current_mode[0],
		managed: current_mode[1],
		requiresTakeover: !current_mode[1],
		catalog: local_catalog,
		selected: mode.selected(content),
		deviceRules: mode.device_rules(content),
		last,
		recentError: last.recentError,
		rollback: last.rollback === true,
		backupAvailable: access(config.BACKUP),
		clashApi: clash_api_status(content, false),
		localDns: local_dns_settings(),
	};
	if (include_config) result.config = content;
	return result;
}

export function advanced() {
	return state(true);
}

export function runtime_dashboard() {
	const content = config.read();
	const status = clash_api_status(content, true);
	const ready = status.browserAccessible && status.secretConfigured;
	let reasons = [];
	if (!status.browserAccessible) push(reasons, 'controller-unreachable');
	if (!status.secretConfigured) push(reasons, 'secret-missing');
	const local_catalog = node.catalog(content);
	const runtime = node.runtime_catalog(content);
	if (runtime.available) subscription.capture_runtime(local_catalog, runtime.nodes);
	const subscription_nodes = runtime.available ? runtime.nodes : subscription.catalog_nodes(local_catalog);
	return { ok: true, ready, needsPreparation: !ready, running: running(), controllerPort: status.port || 9090, secret: ready ? status.secret : '', reasons, configuredNodeCount: length(local_catalog.nodes || []) + length(subscription_nodes), dns: dns.current(content) };
}

export function runtime_prepare(input) {
	if (type(input) !== 'object' || type(input.expectedRevision) !== 'string' || !match(input.expectedRevision, /^[a-fA-F0-9]{64}$/)) return error_result('REVISION_REQUIRED');
	if (config.file_revision() !== input.expectedRevision) return error_result('REVISION_CONFLICT');
	const content = config.read();
	const status = clash_api_status(content, true);
	if (status.browserAccessible && status.secretConfigured) {
		const runtime = runtime_dashboard();
		return { ok: true, changed: false, revision: input.expectedRevision, running: runtime.running, runtime };
	}
	const secret = status.secretConfigured ? status.secret : random_secret();
	if (!secret) return error_result('CLASH_API_INVALID', 'runtime monitoring secret generation failed');
	const candidate = runtime_api_candidate(content, status, secret);
	if (!candidate[0]) return error_result('CLASH_API_INVALID', candidate[1]);
	const result = apply_content(candidate[0], input.expectedRevision, { type: 'runtime-monitoring' }, 'preserve');
	if (result.ok) { result.changed = true; result.runtime = runtime_dashboard(); }
	return result;
}

export function toggle_clash_api(input) {
	if (type(input) !== 'object' || !config.is_bool(input.enabled)) return error_result('CLASH_API_INVALID');
	if (type(input.expectedRevision) !== 'string' || !match(input.expectedRevision, /^[a-fA-F0-9]{64}$/)) return error_result('REVISION_REQUIRED');
	const content = config.read();
	const status = clash_api_status(content, false);
	if (status.enabled === input.enabled) return { ok: true, changed: false, enabled: status.enabled, revision: config.file_revision(), clashApi: status };
	const candidate = clash_api_candidate(content, input.enabled);
	if (!candidate[0]) return error_result('CLASH_API_INVALID', candidate[1]);
	const result = apply_content(candidate[0], input.expectedRevision, { type: 'clash_api', enabled: input.enabled }, 'start');
	if (result.ok) { result.enabled = input.enabled; result.changed = true; result.clashApi = clash_api_status(config.read(), false); }
	return result;
}

export function validate_advanced(content) {
	const validation = config.validate(content);
	if (!validation[0]) return error_result('CONFIG_INVALID', validation[1], { validation: validation[2] });
	return { ok: true, valid: true, revision: config.revision(content) };
}

export function apply_advanced(input) {
	if (type(input) !== 'object' || type(input.config) !== 'string') return error_result('CONFIG_INVALID');
	return apply_content(input.config, input.expectedRevision, { type: 'advanced' }, 'start');
}

export function network_interfaces() {
	const result = network.snapshot(config.read());
	if (!result.ok) return error_result('NETWORK_DISCOVERY_FAILED', result.error, { discovery: result });
	return result;
}

export function apply_interfaces(input) {
	if (type(input) !== 'object') return error_result('INTERFACE_AMBIGUOUS');
	if (type(input.expectedRevision) !== 'string' || !match(input.expectedRevision, /^[a-fA-F0-9]{64}$/)) return error_result('REVISION_REQUIRED');
	const content = config.read();
	const discovery = network.discover();
	if (!discovery.ok) return error_result('NETWORK_DISCOVERY_FAILED', discovery.error, { discovery });
	const current = network.current(content);
	const log_level = lc(config.trim_value(input.logLevel || current.logLevel || 'info'));
	if (!LOG_LEVELS[log_level]) return error_result('LOG_LEVEL_INVALID');
	const selected = network.validate_selection(discovery, input.lanDevice || input.lan || current.lan, input.wanDevice || input.wan || current.wan, input.dialMode || current.dialMode);
	if (!selected[0]) return error_result(selected[1], null, { discovery });
	selected[0].logLevel = log_level;
	let local_dns = null;
	if (input.dnsmasqForwarding != null || input.proxyLocalDns != null || input.localDnsServers != null) {
		const parsed = local_dns_input(input);
		if (!parsed[0]) return error_result(parsed[1]);
		local_dns = parsed[0];
	}
	const candidate = network.update_global(content, selected[0]);
	if (!candidate[0]) return error_result('CONFIG_INVALID', candidate[1]);
	let metadata = { type: 'interfaces', lanDevice: selected[0].lan, wanDevice: selected[0].wan, dialMode: selected[0].dialMode, logLevel: selected[0].logLevel };
	if (local_dns) metadata.localDns = local_dns;
	const result = apply_content(candidate[0], input.expectedRevision, metadata, 'start');
	if (result.ok) {
		result.interfaces = { lan: selected[0].lan, wan: selected[0].wan };
		result.dialMode = selected[0].dialMode;
		result.logLevel = selected[0].logLevel;
		result.localDns = local_dns_settings();
		result.config = config.read();
	}
	return result;
}

export function sources(input) {
	if (type(input) !== 'object') return error_result('SOURCE_ACTION_INVALID');
	const content = config.read();
	const candidate = node.mutate(content, input);
	if (!candidate[0]) return error_result(candidate[1]);
	const result = apply_content(candidate[0], input.expectedRevision, { type: 'source', action: input.action, name: input.name }, 'preserve');
	if (result.ok && input.action === 'add-subscription') {
		for (let item in node.catalog(candidate[0]).subscriptions) {
			if (item.name !== input.name) continue;
			const refreshed = subscription.refresh(item.name, input.url);
			result.cache = refreshed[0] || { source: 'missing', error: refreshed[1] };
			break;
		}
	}
	else if (result.ok && input.action === 'remove-subscription') subscription.remove(input.name);
	return result;
}

export function refresh_subscription(input) {
	if (type(input) !== 'object' || type(input.name) !== 'string' || length(input.name) > 64 || !match(input.name, /^[A-Za-z0-9_.-]+$/)) return error_result('SUBSCRIPTION_REFRESH_FAILED');
	const content = config.read();
	let found = null;
	for (let item in node.catalog(content).subscriptions) if (item.name === input.name) { found = item; break; }
	if (!found) return error_result('SUBSCRIPTION_REFRESH_FAILED', 'subscription not found');
	const url = node.subscription_url(content, found.name);
	if (!url) return error_result('SUBSCRIPTION_REFRESH_FAILED', 'subscription URL is unavailable');
	const refreshed = subscription.refresh(found.name, url);
	if (!refreshed[0]) return error_result('SUBSCRIPTION_REFRESH_FAILED', refreshed[1]);
	let runtime_ok = false, runtime_error = null;
	if (running()) {
		const runtime = node.refresh_subscription(content, input.name);
		runtime_ok = runtime[0];
		runtime_error = runtime[1];
	}
	return { ok: true, accepted: true, name: input.name, cache: refreshed[0], runtimeRefresh: runtime_ok, runtimeError: runtime_error };
}

export function subscription_cache(input) {
	if (type(input) !== 'object' || type(input.name) !== 'string' || !input.name || length(input.name) > 64 || !match(input.name, /^[A-Za-z0-9_.-]+$/)) return error_result('SUBSCRIPTION_REFRESH_FAILED');
	const record = subscription.cache(input.name);
	if (!record) return error_result('SUBSCRIPTION_REFRESH_FAILED', 'subscription cache not found');
	return { ok: true, name: input.name, cache: record };
}

export function delete_subscription_cache(input) {
	if (type(input) !== 'object' || type(input.name) !== 'string' || !input.name || length(input.name) > 64 || !match(input.name, /^[A-Za-z0-9_.-]+$/)) return error_result('SUBSCRIPTION_REFRESH_FAILED');
	if (!subscription.remove(input.name)) return error_result('SUBSCRIPTION_REFRESH_FAILED', 'invalid subscription name');
	return { ok: true, name: input.name, removed: true };
}

export function delay(input) {
	if (type(input) !== 'object' || type(input.name) !== 'string' || !input.name || length(input.name) > 64 || !match(input.name, /^[A-Za-z0-9_.-]+$/)) return error_result('NODE_MISSING');
	const response = node.delay(config.read(), input.name);
	if (response[0]) return { ok: true, name: response[0].name, delay: response[0].delay, target: response[0].target };
	const raw = sprintf('%s', response[1] || 'NODE_DELAY_FAILED');
	let code = 'NODE_DELAY_FAILED', detail = raw;
	for (let known in [ 'NODE_MISSING', 'CLASH_API_UNAVAILABLE', 'DELAY_API_INVALID', 'NODE_DELAY_FAILED' ]) {
		if (raw === known || index(raw, `${known}:`) === 0) { code = known; detail = substr(raw, length(known) + 1); break; }
	}
	return error_result(code, detail || null);
}

function connectivity_target(target) {
	const fd = popen(`/usr/bin/curl -I -o /dev/null -skL --connect-timeout 3 --max-time 8 -w %{http_code}:%{time_pretransfer} ${config.shellquote(target.url)} 2>/dev/null`, 'r');
	const output = fd?.read?.('all') || '';
	fd?.close();
	const parsed = match(output, /^([0-9]+):([0-9.]+)/);
	const status = int(parsed?.[1]);
	const latency = parsed?.[2] != null ? int(+parsed[2] * 1000 + 0.5) : null;
	const ok = status != null && status >= 100 && status < 600;
	let result = { id: target.id, url: target.url, route: target.route, ok, status: status || 0, latency };
	if (!ok) result.error = 'request failed';
	return result;
}

function proxy_connectivity_target(content, target) {
	const response = node.proxy_delay(content, 'honk-proxy', target.url);
	let result = { id: target.id, url: target.url, route: target.route, ok: !!response[0], status: response[0] ? 200 : 0, latency: response[0]?.delay || null };
	if (!result.ok) result.error = response[1] || 'proxy request failed';
	return result;
}

export function connectivity(input) {
	if (!running()) return error_result('SERVICE_FAILED');
	const target_id = type(input) === 'object' ? config.trim_value(input.id) : '';
	let target = null;
	for (let candidate in CONNECTIVITY_TARGETS) if (candidate.id === target_id) { target = candidate; break; }
	if (!target) return error_result('CONNECTIVITY_TARGET_INVALID');
	const result = target.route === 'direct' ? connectivity_target(target) : proxy_connectivity_target(config.read(), target);
	return { ok: true, passed: result.ok, check: result, testedAt: iso_now() };
}

export function service(action) {
	if (!(action in { start: true, stop: true, restart: true })) return error_result('SOURCE_ACTION_INVALID', 'unsupported service action');
	if (action !== 'start') {
		const content = config.read();
		const runtime = node.runtime_catalog(content);
		if (runtime.available) subscription.capture_runtime(node.catalog(content), runtime.nodes);
	}
	if (system(`${config.shellquote(INIT)} ${action} >/dev/null 2>&1`) !== 0) return error_result('SERVICE_FAILED', 'service action failed');
	if (!wait_for_running(action !== 'stop')) return error_result('SERVICE_FAILED', `service ${action} timed out after ${SERVICE_STATE_TIMEOUT} seconds`);
	let last = read_state();
	last.stage = action === 'stop' ? 'stopped' : 'running';
	last.activeRevision = action === 'stop' ? last.activeRevision : config.file_revision();
	last.recentError = null;
	write_state(last);
	return { ok: true, action, state: state(false) };
}

function file_info(path, executable, required) {
	const info = stat(path);
	const exists = !!info;
	const regular = info?.type === 'file';
	const executable_ok = !executable || !!info?.perm?.user_exec;
	let reason = null;
	if (!exists) reason = required === false ? 'not created yet' : 'missing';
	else if (!regular) reason = 'not a regular file';
	else if (!executable_ok) reason = 'not executable';
	return { path, exists, regular, executable: executable_ok, size: info?.size || 0, ok: (!exists && required === false) || (exists && regular && executable_ok), reason };
}

function file_version(item) {
	if (!item.ok) return item;
	const fd = popen(`${config.shellquote(item.path)} --version 2>/dev/null`, 'r');
	item.version = replace(config.trim_value(fd?.read?.('all') || ''), /\n/g, ' ');
	fd?.close();
	return item;
}

function clean_log_output(value) {
	const output = sprintf('%s', value || '');
	let cleaned = '';
	for (let index = 0; index < length(output); index++) {
		const code = ord(output, index);
		if (code === 27) {
			const next = ord(output, index + 1);
			if (next === 91) {
				index += 2;
				while (index < length(output)) {
					const terminal = ord(output, index++);
					if (terminal >= 64 && terminal <= 126) break;
				}
				index--;
			}
			else if (next === 93) {
				index += 2;
				while (index < length(output)) {
					const terminal = ord(output, index++);
					if (terminal === 7 || (terminal === 27 && ord(output, index) === 92)) break;
				}
				index--;
			}
			continue;
		}
		if (code === 13 || (code < 32 && code !== 10) || code === 127) continue;
		cleaned += substr(output, index, 1);
	}
	return cleaned;
}

export function logs() {
	const fd = popen(`/usr/bin/tail -n 300 ${config.shellquote(LOG_FILE)} 2>/dev/null`, 'r');
	const output = fd?.read?.('all') || '';
	fd?.close();
	return { ok: true, lines: config.redact(clean_log_output(output)) };
}

export function clear_logs() {
	if (!access(LOG_FILE)) return { ok: true, cleared: false };
	if (!writefile(LOG_FILE, '')) return error_result('LOG_CLEAR_FAILED');
	chmod(LOG_FILE, 0640);
	return { ok: true, cleared: true };
}

export function diagnostics() {
	const content = config.read();
	const validation = config.validate(content);
	const geo = geo_check();
	let files = {
		core: file_version(file_info('/usr/bin/honk-core', true, true)),
		tool: file_version(file_info(config.HONK_TOOL, true, true)),
		init: file_info(INIT, true, true),
		config: file_info(config.CONFIG, false, true),
		defaultConfig: file_info(config.DEFAULT_CONFIG, false, true),
		backup: file_info(config.BACKUP, false, false),
		launcher: file_info('/usr/libexec/honk/honk-launcher', true, true),
		interfaceDiscovery: file_info('/usr/libexec/honk/interface-discovery', true, true),
		quickWorker: file_info(WORKER, true, true),
		geosite: file_info(`${GEO_DIR}/geosite.dat`, false, true),
		geoip: file_info(`${GEO_DIR}/geoip.dat`, false, true),
	};
	files.valid = true;
	for (let key, item in files) if (key !== 'valid' && item.ok !== true) { files.valid = false; break; }
	return { ok: true, service: { running: running(), init: access(INIT) }, config: { valid: validation[0], detail: validation[1], revision: config.file_revision(), bytes: length(content) }, geo: { valid: geo[0], detail: geo[1] }, files, validation: validation[2], last: read_state() };
}
