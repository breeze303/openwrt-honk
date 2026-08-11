// SPDX-License-Identifier: Apache-2.0
'use strict';

import * as config from 'luci.honk.config';
import * as dns from 'luci.honk.dns';
import * as node from 'luci.honk.node';
import * as subscription from 'luci.honk.subscription';

export const DEFAULT_BOOTSTRAP_RESOLVER = 'udp://223.5.5.5:53';
export const MODES = {
	'china-direct': { label: '国内直连', geoSite: [ 'cn' ], geoIp: [ 'private', 'cn' ] },
	gfwlist: { label: 'GFW', geoSite: [ 'gfw' ], geoIp: [ 'private' ] },
	'china-proxy': { label: '国内代理', geoSite: [ 'cn' ], geoIp: [ 'private', 'cn' ] },
	global: { label: '全局模式', geoSite: [], geoIp: [ 'private' ] },
};

const FIXED_ROUTING_RULES = [
	'pname(NetworkManager, systemd-resolved, dnsmasq) -> direct(must)',
	'dip(geoip: private) -> direct',
];

function routing_body(content) {
	const found = config.section(content, 'routing');
	return found[0] ? config.section_body(content, found[0]) : '';
}

function marker_mode(content) {
	const value = match(sprintf('%s', content || ''), /luci-app-honk\s+managed:\s*v1\s+mode=([A-Za-z0-9_-]+)/)?.[1];
	return MODES[value] ? value : null;
}

function fallback(body) {
	for (let line in split(sprintf('%s', body || ''), '\n')) {
		const value = match(replace(line, /#.*/, ''), /^\s*fallback\s*:\s*([A-Za-z0-9_.-]+)/)?.[1];
		if (value) return value;
	}
	return null;
}

export function detect(content) {
	const marked = marker_mode(content);
	if (marked) return [marked, true];
	const body = routing_body(content);
	const target = fallback(body);
	if (!target) return [null, false];
	if (match(body, /domain\s*\(\s*geosite:\s*gfw\s*\)\s*->\s*[A-Za-z0-9_.-]+/) && target === 'direct') return [ 'gfwlist', true ];
	const china_direct = match(body, /dip\s*\(\s*geoip:\s*cn\s*\)\s*->\s*direct/) && match(body, /domain\s*\(\s*geosite:\s*cn\s*\)\s*->\s*direct/);
	if (china_direct && target !== 'direct') return [ 'china-direct', true ];
	const china_ip_target = match(body, /dip\s*\(\s*geoip:\s*cn\s*\)\s*->\s*([A-Za-z0-9_.-]+)/)?.[1];
	const china_domain_target = match(body, /domain\s*\(\s*geosite:\s*cn\s*\)\s*->\s*([A-Za-z0-9_.-]+)/)?.[1];
	if (china_ip_target && china_ip_target !== 'direct' && china_domain_target === china_ip_target && target === 'direct') return [ 'china-proxy', true ];
	let significant = 0;
	for (let line in split(body, '\n')) {
		const clean = config.trim_value(replace(line, /#.*/, ''));
		if (index(clean, '->') < 0) continue;
		if (clean === 'pname(NetworkManager, systemd-resolved, dnsmasq) -> direct(must)' || clean === 'dip(geoip: private) -> direct' ||
			clean === 'dip(geoip: private) && !dport(53) -> direct(must)' || clean === 'dip(geoip: private) -> direct(must)' ||
			clean === 'pname(dnsmasq) && l4proto(udp) && dport(53) -> direct(must)' || clean === 'pname(dnsmasq) -> direct(must)') continue;
		significant++;
	}
	if (target !== 'direct' && significant === 0) return [ 'global', true ];
	return [null, false];
}

function selected_group(content) {
	const outer = config.section(content, 'group');
	if (!outer[0]) return { nodes: [], subscriptions: [] };
	const body = config.section_body(content, outer[0]);
	const parsed = config.parse(body);
	if (!parsed[0]) return { nodes: [], subscriptions: [] };
	let group = null;
	for (let candidate in parsed[0].sections)
		if (candidate.name === 'honk-proxy' || candidate.name === 'quick-proxy') { group = candidate; break; }
	if (!group) return { nodes: [], subscriptions: [] };
	const group_body = config.section_body(body, group);
	let result = { nodes: [], subscriptions: [] }, seen = {};
	for (let line in split(group_body, '\n')) {
		let found = match(line, /^\s*filter\s*:\s*(name)\s*\((.*?)\)\s*$/);
		if (!found) found = match(line, /^\s*filter\s*:\s*(subscription)\s*\((.*?)\)\s*$/);
		if (!found) continue;
		const kind = found[1], arguments = found[2];
		for (let quoted in match(arguments, /['"]([^'"]+)['"]/g) || []) {
			const value = quoted[1];
			const key = `${kind}:${value}`;
			if (seen[key]) continue;
			push(kind === 'name' ? result.nodes : result.subscriptions, value);
			seen[key] = true;
		}
	}
	return result;
}

export function selected(content) {
	return selected_group(content);
}

export function device_rules(content) {
	let result = [];
	for (let line in split(routing_body(content), '\n')) {
		let matched = match(line, /^\s*sip\s*\(([^)]+)\)\s*->\s*([A-Za-z0-9_.-]+)\s*$/);
		if (matched) push(result, { kind: 'ip', value: config.trim_value(matched[1]), outbound: matched[2] === 'direct' ? 'direct' : 'proxy' });
		matched = match(line, /^\s*mac\s*\(([^)]+)\)\s*->\s*([A-Za-z0-9_.-]+)\s*$/);
		if (matched) push(result, { kind: 'mac', value: config.trim_value(matched[1]), outbound: matched[2] === 'direct' ? 'direct' : 'proxy' });
	}
	return result;
}

function render_global(content) {
	const found = config.section(content, 'global');
	if (found[0]) {
		let body = config.ensure_key(config.section_body(content, found[0]), 'bootstrap_resolver', DEFAULT_BOOTSTRAP_RESOLVER);
		if (config.trim_value(body)) return `global {${body}}`;
	}
	return join('\n', [
		'global {',
		`\tbootstrap_resolver: ${config.daequote(DEFAULT_BOOTSTRAP_RESOLVER)}`,
		'\twan_interface: auto',
		'\tlan_interface: auto',
		'\tlog_level: info',
		'\tdial_mode: domain',
		'\tauto_config_kernel_parameter: true',
		'}',
	]);
}

function normalize_device_rules(rules) {
	if (type(rules) !== 'array' || length(rules) > 64) return [null, 'DEVICE_RULES_INVALID'];
	let result = [], seen = {};
	for (let rule in rules) {
		if (type(rule) !== 'object' || !(rule.kind in { ip: true, mac: true }) || !(rule.outbound in { direct: true, proxy: true })) return [null, 'DEVICE_RULE_INVALID'];
		const value = config.trim_value(rule.value);
		if (rule.kind === 'ip' && !match(value, /^[A-Fa-f0-9.:/]+$/)) return [null, 'DEVICE_IP_INVALID'];
		if (rule.kind === 'mac' && !match(value, /^[A-Fa-f0-9]{2}(:[A-Fa-f0-9]{2}){5}$/)) return [null, 'DEVICE_MAC_INVALID'];
		const key = `${rule.kind}:${value}`;
		if (seen[key]) return [null, 'DEVICE_RULE_DUPLICATE'];
		seen[key] = true;
		push(result, { kind: rule.kind, value, outbound: rule.outbound });
	}
	return [result, null];
}

function render_group(selection) {
	let lines = [ 'group {', '\thonk-proxy {' ];
	for (let line in node.filters(selection)) push(lines, line);
	push(lines, '\t\tpolicy: selector');
	if (length(selection.nodes || []) === 1) push(lines, `\t\tdefault: ${config.daequote(selection.nodes[0])}`);
	push(lines, '\t\tfinal: direct');
	push(lines, '\t}');
	push(lines, '}');
	return join('\n', lines);
}

function render_routing(mode, rules) {
	let lines = [ 'routing {' ];
	for (let rule in FIXED_ROUTING_RULES) push(lines, `\t${rule}`);
	for (let rule in rules) {
		const condition = rule.kind === 'ip' ? `sip(${rule.value})` : `mac(${rule.value})`;
		push(lines, `\t${condition} -> ${rule.outbound === 'direct' ? 'direct' : 'honk-proxy'}`);
	}
	if (mode === 'gfwlist') {
		push(lines, '\tdomain(geosite: gfw) -> honk-proxy');
		push(lines, '\tfallback: direct');
	}
	else if (mode === 'china-direct') {
		push(lines, '\tdip(geoip: cn) -> direct');
		push(lines, '\tdomain(geosite: cn) -> direct');
		push(lines, '\tfallback: honk-proxy');
	}
	else if (mode === 'china-proxy') {
		push(lines, '\tdip(geoip: cn) -> honk-proxy');
		push(lines, '\tdomain(geosite: cn) -> honk-proxy');
		push(lines, '\tfallback: direct');
	}
	else if (mode === 'global') push(lines, '\tfallback: honk-proxy');
	push(lines, '}');
	return [join('\n', lines), lines];
}

export function compile(content, input) {
	if (type(input) !== 'object' || !MODES[input.mode]) return [null, 'MODE_UNKNOWN'];
	const parsed = config.parse(content);
	if (!parsed[0]) return [null, `CONFIG_PARSE_FAILED:${parsed[1]}`];
	const runtime = node.runtime_catalog(content);
	let runtime_names = [];
	for (let item in runtime.nodes || []) push(runtime_names, item.name);
	for (let item in subscription.catalog_nodes(node.catalog(content))) push(runtime_names, item.name);
	const selection = node.select(content, {
		nodeNames: input.nodeNames || [],
		subscriptionNames: input.subscriptionNames || [],
		runtimeNodeNames: runtime_names,
	});
	if (!selection[0]) return [null, selection[1]];
	const normalized = normalize_device_rules(input.deviceRules || device_rules(content));
	if (!normalized[0]) return [null, normalized[1]];
	const current_dns = dns.current(content);
	const rendered_dns = dns.render(input.mode, {
		bind: current_dns.bind,
		direct: input.directDns || current_dns.direct,
		proxy: input.proxyDns || current_dns.proxy,
	});
	if (!rendered_dns[0]) return [null, rendered_dns[1]];
	const routing = render_routing(input.mode, normalized[0]);
	const candidate = config.replace_managed(content, [ render_global(content), render_group(selection[0]), routing[0], rendered_dns[0] ], `# luci-app-honk managed: v1 mode=${input.mode}`);
	if (!candidate[0]) return [null, `CONFIG_REBUILD_FAILED:${candidate[1]}`];
	const previous = detect(content);
	return [{
		candidate: candidate[0],
		mode: input.mode,
		previousMode: previous[0],
		requiresTakeover: !previous[1],
		selected: selection[0],
		deviceRules: normalized[0],
		routingLines: routing[1],
		dnsRules: rendered_dns[2],
	}, null];
}

export function geo_requirements(mode) {
	return MODES[mode] || null;
}
