// SPDX-License-Identifier: Apache-2.0
'use strict';

import { popen } from 'fs';
import * as config from 'luci.honk.config';

export const DELAY_URL = 'https://www.gstatic.com/generate_204';
export const DELAY_TIMEOUT = 8000;

const RESERVED = { direct: true, block: true, 'honk-proxy': true, 'quick-proxy': true };
const NODE_SCHEMES = {
	ss: true, ss2022: true, vmess: true, vless: true, trojan: true,
	tuic: true, hysteria2: true, anytls: true, juicity: true,
	socks5: true, socks: true, http: true, https: true,
};

function valid_name(name) {
	return type(name) === 'string' && length(name) <= 64 && match(name, /^[A-Za-z0-9_.-]+$/) && !RESERVED[name];
}

// Runtime node labels come from upstream subscriptions and may contain UTF-8,
// whitespace, or emoji. They are only ever URL encoded or DAE quoted.
export function valid_runtime_node_name(name) {
	if (type(name) !== 'string' || length(name) < 1 || length(name) > 256 || RESERVED[name]) return false;
	for (let index = 0; index < length(name); index++) {
		const code = ord(name, index);
		if (code < 32 || code === 127) return false;
	}
	return true;
}

function valid_group_name(name) {
	return type(name) === 'string' && length(name) <= 64 && match(name, /^[A-Za-z0-9_.-]+$/);
}

function protocol(value) {
	return match(sprintf('%s', value ?? ''), /^([A-Za-z0-9+.-]+):\/\//)?.[1] || null;
}

function subscription_parts(body) {
	const parts = config.nested_sections(body);
	if (!parts[0]) return [null, ''];
	let flat = body;
	for (let index = length(parts[0]) - 1; index >= 0; index--) {
		const entry = parts[0][index];
		flat = `${substr(flat, 0, entry.start)}${substr(flat, entry.finish + 1)}`;
	}
	return [parts[0], flat];
}

function subscription_catalog(body) {
	let result = [], nested_by_name = {};
	const parts = subscription_parts(body);
	if (!parts[0]) return result;
	for (let entry in parts[0]) {
		const values = config.key_values(config.section_body(body, entry));
		if (!values.url) continue;
		nested_by_name[entry.name] = true;
		push(result, {
			name: entry.name,
			kind: 'subscription',
			protocol: protocol(values.url) || 'http',
			enabled: lc(config.trim_value(values.enabled || 'true')) !== 'false',
			updateInterval: int(values.update_interval || 86400) || 86400,
		});
	}
	for (let entry in config.named_entries(parts[1])) {
		if (nested_by_name[entry.name]) continue;
		push(result, {
			name: entry.name,
			kind: 'subscription',
			protocol: protocol(entry.value) || 'http',
			enabled: true,
			updateInterval: 86400,
		});
	}
	return result;
}

export function catalog(content) {
	let nodes = [], subscriptions = [];
	const node_section = config.section(content, 'node');
	if (node_section[0]) {
		for (let entry in config.named_entries(config.section_body(content, node_section[0])))
			push(nodes, { name: entry.name, kind: 'node', protocol: protocol(entry.value) || 'unknown' });
	}
	const subscription_section = config.section(content, 'subscription');
	if (subscription_section[0]) subscriptions = subscription_catalog(config.section_body(content, subscription_section[0]));
	nodes = sort(nodes, (left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
	subscriptions = sort(subscriptions, (left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
	return { nodes, subscriptions };
}

// The dashboard catalog intentionally contains subscription metadata only.
// Refresh paths resolve the URL from the protected configuration server-side.
export function subscription_url(content, name) {
	if (type(name) !== 'string' || !name) return null;
	const outer = config.section(content, 'subscription');
	if (!outer[0]) return null;
	const body = config.section_body(content, outer[0]);
	const parts = subscription_parts(body);
	if (!parts[0]) return null;
	for (let entry in parts[0]) {
		if (entry.name !== name) continue;
		const url = config.key_values(config.section_body(body, entry)).url;
		if (type(url) === 'string' && url) return url;
	}
	for (let entry in config.named_entries(parts[1]))
		if (entry.name === name && type(entry.value) === 'string' && entry.value) return entry.value;
	return null;
}

function url_encode(value) {
	let encoded = '';
	value = sprintf('%s', value ?? '');
	for (let index = 0; index < length(value); index++) {
		const chr = substr(value, index, 1);
		encoded += match(chr, /^[A-Za-z0-9_.~-]$/) ? chr : sprintf('%%%02X', ord(value, index));
	}
	return encoded;
}

function clash_api(content) {
	const experimental = config.section(content, 'experimental');
	if (!experimental[0]) return null;
	const body = config.section_body(content, experimental[0]);
	const clash = config.section(body, 'clash_api');
	if (!clash[0]) return null;
	const values = config.key_values(config.section_body(body, clash[0]));
	const controller = config.trim_value(values.external_controller);
	const port = match(controller, /:([0-9]+)$/)?.[1];
	if (!port || int(port) < 1 || int(port) > 65535) return null;
	const secret = config.trim_value(values.secret);
	const headers = secret ? ` --header=${config.shellquote(`Authorization: Bearer ${secret}`)}` : '';
	return [ `http://127.0.0.1:${port}`, headers ];
}

function runtime_request(url, headers) {
	const fd = popen(`/usr/bin/wget -q -T 2 -t 1${headers || ''} -O - ${config.shellquote(url)} 2>/dev/null`, 'r');
	const output = fd?.read?.('all') || '';
	fd?.close();
	try { return json(output); } catch (e) { return null; }
}

function runtime_delay_request(url, headers) {
	const fd = popen(`/usr/bin/curl -sS -m 12${headers || ''} -o - ${config.shellquote(url)} 2>/dev/null`, 'r');
	const output = fd?.read?.('all') || '';
	fd?.close();
	try { return json(output); } catch (e) { return null; }
}

export function refresh_subscription(content, name) {
	if (!valid_name(name)) return [false, 'SUBSCRIPTION_MISSING'];
	const api = clash_api(content);
	if (!api) return [false, 'CLASH_API_UNAVAILABLE'];
	const url = `${api[0]}/subscriptions/${url_encode(name)}/refresh`;
	const fd = popen(`/usr/bin/wget -q -T 3 -t 1 --post-data=''${api[1] || ''} -O /dev/null ${config.shellquote(url)} 2>/dev/null`, 'r');
	fd?.read?.('all');
	const code = fd ? fd.close() : 127;
	return [code === 0, code === 0 ? null : 'Honk subscription endpoint is unavailable'];
}

function protocol_name(value) {
	const raw = lc(sprintf('%s', value || 'unknown'));
	return ({ shadowsocks: 'ss', vmess: 'vmess', vless: 'vless', trojan: 'trojan', hysteria2: 'hysteria2', tuic: 'tuic', juicity: 'juicity', anytls: 'anytls', socks5: 'socks5', http: 'http' })[raw] || raw;
}

function configured_groups(content) {
	let result = {};
	const outer = config.section(content, 'group');
	if (!outer[0]) return result;
	const parsed = config.parse(config.section_body(content, outer[0]));
	if (!parsed[0]) return result;
	for (let entry in parsed[0].sections) result[entry.name] = true;
	return result;
}

export function runtime_catalog(content) {
	const local_catalog = catalog(content);
	if (!length(local_catalog.subscriptions)) return { nodes: [], available: false, configured: false };
	const api = clash_api(content);
	if (!api) return { nodes: [], available: false, configured: false };
	let ownership = {};
	const subscription_state = runtime_request(`${api[0]}/subscriptions`, api[1]);
	if (type(subscription_state) === 'object' && type(subscription_state.subscriptions) === 'object') {
		for (let item in subscription_state.subscriptions) {
			if (type(item) !== 'object' || type(item.name) !== 'string' || type(item.nodes) !== 'array') continue;
			for (let node in item.nodes)
				if (type(node) === 'object' && type(node.name) === 'string' && node.name) ownership[node.name] = item.name;
		}
	}
	const response = runtime_request(`${api[0]}/proxies`, api[1]);
	if (type(response) !== 'object' || type(response.proxies) !== 'object')
		return { nodes: [], available: false, configured: true };
	let excluded = {}, nodes = [], seen = {};
	for (let item in local_catalog.nodes) excluded[item.name] = true;
	for (let name in configured_groups(content)) excluded[name] = true;
	for (let name, item in response.proxies) {
		if (type(name) !== 'string' || name in { GLOBAL: true, Proxy: true, direct: true, block: true } || excluded[name] ||
			type(item) !== 'object' || type(item.all) === 'array' || seen[name]) continue;
		seen[name] = true;
		push(nodes, { name, subscription: ownership[name] || 'runtime', protocol: protocol_name(item.type) });
	}
	nodes = sort(nodes, (left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
	return { nodes, available: true, configured: true };
}

function catalog_has_node(content, name) {
	for (let item in catalog(content).nodes)
		if (item.name === name) return true;
	for (let item in runtime_catalog(content).nodes)
		if (item.name === name) return true;
	return false;
}

export function delay(content, name) {
	if (!valid_runtime_node_name(name) || !catalog_has_node(content, name)) return [null, `NODE_MISSING:${name || ''}`];
	const api = clash_api(content);
	if (!api) return [null, 'CLASH_API_UNAVAILABLE'];
	const url = `${api[0]}/proxies/${url_encode(name)}/delay?url=${url_encode(DELAY_URL)}&timeout=${DELAY_TIMEOUT}`;
	const response = runtime_delay_request(url, api[1]);
	if (type(response) !== 'object') return [null, 'DELAY_API_INVALID'];
	const measured = int(response.delay);
	if (measured != null && measured >= 0) return [{ name, delay: measured, target: DELAY_URL }, null];
	return [null, config.trim_value(response.message || 'NODE_DELAY_FAILED')];
}

export function proxy_delay(content, group_name, target) {
	if (!valid_group_name(group_name) || type(target) !== 'string' || !target || length(target) > 512) return [null, 'NODE_DELAY_FAILED'];
	const api = clash_api(content);
	if (!api) return [null, 'CLASH_API_UNAVAILABLE'];
	const url = `${api[0]}/proxies/${url_encode(group_name)}/delay?url=${url_encode(target)}&timeout=${DELAY_TIMEOUT}`;
	const response = runtime_delay_request(url, api[1]);
	if (type(response) !== 'object') return [null, 'DELAY_API_INVALID'];
	const measured = int(response.delay);
	if (measured != null && measured >= 0) return [{ name: group_name, delay: measured, target }, null];
	return [null, config.trim_value(response.message || 'NODE_DELAY_FAILED')];
}

export function set_group_selection(content, group_name, node_name) {
	if (!valid_group_name(group_name) || !valid_runtime_node_name(node_name)) return [false, 'NODE_MISSING'];
	const api = clash_api(content);
	if (!api) return [false, 'CLASH_API_UNAVAILABLE'];
	const body = sprintf('%J', { name: node_name });
	const url = `${api[0]}/proxies/${url_encode(group_name)}`;
	const fd = popen(`/usr/bin/curl -sS -m 5 -o /dev/null -w '%{http_code}' -X PUT${api[1] || ''} -H ${config.shellquote('Content-Type: application/json')} --data-raw ${config.shellquote(body)} ${config.shellquote(url)} 2>/dev/null`, 'r');
	const output = fd?.read?.('all') || '';
	fd?.close();
	const status = int(trim(output));
	return [status === 200 || status === 204, status != null ? `HTTP_${status}` : 'CLASH_API_UNAVAILABLE'];
}

function names_set(list) {
	let result = {};
	for (let item in list || []) {
		const name = type(item) === 'object' ? item.name : item;
		if (type(name) === 'string' && name) result[name] = true;
	}
	return result;
}

export function select(content, input) {
	input = type(input) === 'object' ? input : {};
	const local_catalog = catalog(content);
	const available_nodes = names_set(local_catalog.nodes);
	const available_subscriptions = names_set(local_catalog.subscriptions);
	const available_runtime = names_set(input.runtimeNodeNames);
	if (type(input.nodeNames) !== 'array' || type(input.subscriptionNames) !== 'array') return [null, 'PROXY_SOURCE_INVALID'];
	if (length(input.nodeNames) + length(input.subscriptionNames) > 32) return [null, 'PROXY_SOURCE_LIMIT'];
	let nodes = [], subscriptions = [], seen = {};
	for (let name in input.nodeNames) {
		if (!valid_runtime_node_name(name) || (!available_nodes[name] && !available_runtime[name])) return [null, `NODE_MISSING:${sprintf('%s', name)}`];
		if (!seen[`node:${name}`]) { push(nodes, name); seen[`node:${name}`] = true; }
	}
	for (let name in input.subscriptionNames) {
		if (!valid_name(name) || !available_subscriptions[name]) return [null, `SUBSCRIPTION_MISSING:${sprintf('%s', name)}`];
		if (!seen[`subscription:${name}`]) { push(subscriptions, name); seen[`subscription:${name}`] = true; }
	}
	if (!length(nodes) && !length(subscriptions)) return [null, 'PROXY_SOURCE_REQUIRED'];
	return [{ nodes, subscriptions }, null];
}

export function filters(selected) {
	let lines = [];
	for (let name in selected.nodes || []) push(lines, `\t\tfilter: name(${config.daequote(name)})`);
	for (let name in selected.subscriptions || []) push(lines, `\t\tfilter: subscription(${config.daequote(name)})`);
	return lines;
}

function append_body(body, value) {
	const clean = rtrim(sprintf('%s', body || ''));
	return clean ? `${clean}\n${value}\n` : `\n${value}\n`;
}

function remove_flat_line(body, name, sections) {
	let output = [], removed = false, offset = 0, section_index = 0;
	for (let line in split(`${body || ''}\n`, '\n')) {
		let section = sections?.[section_index];
		while (section && offset > section.finish) { section_index++; section = sections[section_index]; }
		const nested = section && offset >= section.start && offset <= section.finish;
		const key = match(line, /^\s*([A-Za-z0-9_.-]+)\s*:/)?.[1];
		if (!nested && key === name) removed = true;
		else push(output, line);
		offset += length(line) + 1;
	}
	return [join('\n', output), removed];
}

function mutate_node(content, action, input) {
	const found = config.section(content, 'node');
	let body = found[0] ? config.section_body(content, found[0]) : '';
	if (action === 'add-node') {
		const scheme = protocol(input.url);
		if (!valid_name(input.name)) return [null, 'NODE_NAME_INVALID'];
		if (!scheme || !NODE_SCHEMES[lc(scheme)] || type(input.url) !== 'string' || length(input.url) > 4096) return [null, 'NODE_URL_INVALID'];
		for (let entry in config.named_entries(body)) if (entry.name === input.name) return [null, 'NODE_DUPLICATE'];
		body = append_body(body, `\t${input.name}: ${config.daequote(input.url)}`);
	}
	else if (action === 'remove-node') {
		if (!valid_name(input.name)) return [null, 'NODE_MISSING'];
		const removed = remove_flat_line(body, input.name);
		body = removed[0];
		if (!removed[1]) return [null, 'NODE_MISSING'];
	}
	else return [null, 'NODE_ACTION_INVALID'];
	return config.replace_section(content, 'node', `node {${body}}`);
}

function mutate_subscription(content, action, input) {
	const found = config.section(content, 'subscription');
	let body = found[0] ? config.section_body(content, found[0]) : '';
	const known = subscription_catalog(body);
	if (action === 'add-subscription') {
		if (!valid_name(input.name)) return [null, 'SUBSCRIPTION_NAME_INVALID'];
	if (type(input.url) !== 'string' || !match(input.url, /^https?:\/\/[^[:space:]]+$/) || length(input.url) > 4096) return [null, 'SUBSCRIPTION_URL_INVALID'];
		for (let item in known) if (item.name === input.name) return [null, 'SUBSCRIPTION_DUPLICATE'];
		const interval = int(input.updateInterval ?? 86400);
		if (interval == null || interval < 0 || interval > 604800) return [null, 'SUBSCRIPTION_INTERVAL_INVALID'];
		body = append_body(body, join('\n', [
			`\t${input.name} {`,
			`\t\turl: ${config.daequote(input.url)}`,
			`\t\tupdate_interval: ${interval}`,
			'\t\tenabled: true',
			'\t}',
		]));
	}
	else if (action === 'remove-subscription') {
		if (!valid_name(input.name)) return [null, 'SUBSCRIPTION_MISSING'];
		const sections = config.nested_sections(body);
		if (!sections[0]) return [null, 'SUBSCRIPTION_MISSING'];
		let removed = false;
		for (let index = length(sections[0]) - 1; index >= 0; index--) {
			const entry = sections[0][index];
			if (entry.name === input.name) {
				body = `${substr(body, 0, entry.start)}${substr(body, entry.finish + 1)}`;
				removed = true;
			}
		}
		const remaining = config.nested_sections(body);
		if (!remaining[0]) return [null, 'SUBSCRIPTION_MISSING'];
		const flat = remove_flat_line(body, input.name, remaining[0]);
		body = flat[0];
		removed = removed || flat[1];
		if (!removed) return [null, 'SUBSCRIPTION_MISSING'];
	}
	else return [null, 'SUBSCRIPTION_ACTION_INVALID'];
	return config.replace_section(content, 'subscription', `subscription {${body}}`);
}

export function mutate(content, input) {
	if (type(input) !== 'object' || type(input.action) !== 'string') return [null, 'SOURCE_ACTION_INVALID'];
	if (input.action === 'add-node' || input.action === 'remove-node') return mutate_node(content, input.action, input);
	if (input.action === 'add-subscription' || input.action === 'remove-subscription') return mutate_subscription(content, input.action, input);
	return [null, 'SOURCE_ACTION_INVALID'];
}
