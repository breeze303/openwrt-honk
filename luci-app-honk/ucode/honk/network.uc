// SPDX-License-Identifier: Apache-2.0
'use strict';

import { connect } from 'ubus';
import * as config from 'luci.honk.config';

export const DEFAULT_BOOTSTRAP_RESOLVER = 'udp://223.5.5.5:53';
export const DIAL_MODES = { ip: true, domain: true, 'domain+': true, 'domain++': true };

function reason(list, code) {
	if (index(list, code) < 0) push(list, code);
}

function device_kind(name, status) {
	if (status.bridge || match(name, /^br-/)) return 'bridge';
	if (index(name, '.') >= 0) return 'vlan';
	if (status.type === 'tunnel' || match(name, /^(ppp|tun|wg)/)) return 'tunnel';
	return 'device';
}

function addresses(item) {
	let result = [];
	for (let address in item['ipv4-address'] || [])
		push(result, { family: 'ipv4', address: config.trim_value(address.address), prefix: int(address.mask || 0) || 0 });
	for (let address in item['ipv6-address'] || [])
		push(result, { family: 'ipv6', address: config.trim_value(address.address), prefix: int(address.mask || 0) || 0 });
	return result;
}

function default_routes(item) {
	let result = [], best = null;
	for (let route in item.route || []) {
		const target = config.trim_value(route.target || route.dest);
		if (!(target in { '0.0.0.0': true, '::': true, '0.0.0.0/0': true, '::/0': true })) continue;
		const entry = {
			family: index(target, ':') >= 0 ? 'ipv6' : 'ipv4',
			metric: int(route.metric || 0) || 0,
			gateway: config.trim_value(route.nexthop || route.gateway),
		};
		push(result, entry);
		if (!best || entry.metric < best.metric) best = entry;
	}
	return [result, best];
}

function inspect_dump(dump, device_status) {
	let interfaces = [];
	for (let item in dump.interface || []) {
		const logical = config.trim_value(item.interface || item.name);
		const l3 = config.trim_value(item.l3_device);
		const routes = default_routes(item);
		push(interfaces, {
			logicalName: logical,
			l3Device: l3,
			device: config.trim_value(item.device),
			addresses: addresses(item),
			defaultRoute: routes[1],
			defaultRoutes: routes[0],
			selectedBy: logical === 'lan' ? 'lan' : (routes[1] ? 'default-route' : 'none'),
			safe: !!l3,
			present: false,
			up: false,
			kind: 'unknown',
			reasonCodes: l3 ? [] : [ 'L3_DEVICE_MISSING' ],
		});
	}
	for (let item in interfaces) {
		const status = item.l3Device ? (device_status(item.l3Device) || {}) : {};
		item.present = status.present !== false && (status.present === true || status.exists === true || !!item.l3Device);
		item.up = status.up !== false;
		item.parent = config.trim_value(status.parent);
		item.kind = device_kind(item.l3Device, status);
		if (length(item.defaultRoutes) > 1) reason(item.reasonCodes, 'MULTIPLE_DEFAULT_ROUTES');
		if (!item.present) reason(item.reasonCodes, 'DEVICE_MISSING');
		if (!item.up) reason(item.reasonCodes, 'DEVICE_DOWN');
		item.safe = item.safe && item.present && item.up;
	}
	let lan = null, wan = null, wan_metric = null;
	for (let item in interfaces) {
		if (item.logicalName === 'lan' && item.safe && length(item.addresses) > 0 && !lan) lan = item;
		if (item.defaultRoute && item.safe && (wan_metric == null || item.defaultRoute.metric < wan_metric)) {
			wan = item;
			wan_metric = item.defaultRoute.metric;
		}
	}
	let candidates = [];
	for (let item in interfaces)
		if (item.safe && item.l3Device && item.l3Device !== 'lo') push(candidates, item);
	const ambiguous = !lan || !wan || lan.l3Device === wan.l3Device;
	return {
		ok: true,
		interfaces,
		candidates,
		recommended: { lan: lan?.l3Device, wan: wan?.l3Device },
		ambiguous,
		reasonCodes: ambiguous ? [ 'INTERFACE_AMBIGUOUS' ] : [],
	};
}

// Kept separate from ubus so fixtures can exercise the same interface
// normalization and selection logic without executing shell commands.
export function inspect(dump, statuses) {
	statuses = type(statuses) === 'object' ? statuses : {};
	return inspect_dump(type(dump) === 'object' ? dump : {}, name => statuses[name] || {});
}

export function discover() {
	const ubus = connect();
	if (!ubus) return { ok: false, interfaces: [], candidates: [], recommended: {}, ambiguous: true, error: 'UBUS_UNAVAILABLE' };
	const dump = ubus.call('network.interface', 'dump', {}) || {};
	return inspect_dump(dump, name => ubus.call('network.device', 'status', { name }) || {});
}

export function current(content) {
	const found = config.section(content || config.read(), 'global');
	const values = found[0] ? config.key_values(config.section_body(content || config.read(), found[0])) : {};
	const dial = config.trim_value(values.dial_mode);
	const log = config.trim_value(values.log_level);
	return {
		lan: config.trim_value(values.lan_interface),
		wan: config.trim_value(values.wan_interface),
		dialMode: dial || 'domain',
		logLevel: lc(log || 'info'),
	};
}

function replace_key(body, key, value) {
	let lines = split(body || '', '\n'), changed = false;
	for (let i = 0; i < length(lines); i++) {
		const found = match(lines[i], /^(\s*)([A-Za-z0-9_.-]+)(\s*:\s*)[^\n]*$/);
		if (!found || found[2] !== key || changed) continue;
		lines[i] = `${found[1]}${key}${found[3]}${config.daequote(value)}`;
		changed = true;
	}
	if (changed) return join('\n', lines);
	const trailing = match(body || '', /(\s*)$/)?.[1] || '';
	const head = substr(body || '', 0, length(body || '') - length(trailing));
	return `${head}\n\t${key}: ${config.daequote(value)}${trailing}`;
}

export function update_global(content, values) {
	const found = config.section(content, 'global');
	if (found[1]) return [null, found[1]];
	if (!found[0]) {
		let lines = [
			'global {',
			`\tbootstrap_resolver: ${config.daequote(DEFAULT_BOOTSTRAP_RESOLVER)}`,
			`\twan_interface: ${config.daequote(values.wan)}`,
			`\tlan_interface: ${config.daequote(values.lan)}`,
			`\tdial_mode: ${config.daequote(values.dialMode)}`,
		];
		if (values.logLevel) push(lines, `\tlog_level: ${config.daequote(values.logLevel)}`);
		push(lines, '}');
		return config.replace_section(content, 'global', join('\n', lines));
	}
	const entry = found[0];
	let body = config.section_body(content, entry);
	body = config.ensure_key(body, 'bootstrap_resolver', DEFAULT_BOOTSTRAP_RESOLVER);
	body = replace_key(body, 'lan_interface', values.lan);
	body = replace_key(body, 'wan_interface', values.wan);
	body = replace_key(body, 'dial_mode', values.dialMode);
	if (values.logLevel) body = replace_key(body, 'log_level', values.logLevel);
	return [`${substr(content, 0, entry.start)}global {${body}}${substr(content, entry.finish + 1)}`, null];
}

export function validate_selection(discovery, lan, wan, dial_mode) {
	lan = config.trim_value(lan);
	wan = config.trim_value(wan);
	dial_mode = config.trim_value(dial_mode);
	if (!lan || !wan || lan === 'auto' || wan === 'auto') return [null, 'INTERFACE_AMBIGUOUS'];
	if (!DIAL_MODES[dial_mode]) return [null, 'DIAL_MODE_INVALID'];
	let found_lan = null, found_wan = null;
	for (let item in discovery.candidates || []) {
		if (item.safe && item.l3Device === lan) found_lan = item;
		if (item.safe && item.l3Device === wan) found_wan = item;
	}
	if (!found_lan || !found_wan) return [null, 'INTERFACE_NOT_AVAILABLE'];
	if (lan === wan) return [null, 'INTERFACE_SAME'];
	return [{ lan, wan, dialMode: dial_mode, lanInfo: found_lan, wanInfo: found_wan }, null];
}

export function snapshot(content) {
	const result = discover();
	result.current = current(content);
	result.revision = config.file_revision();
	return result;
}
