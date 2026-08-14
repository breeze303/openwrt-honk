// SPDX-License-Identifier: Apache-2.0
'use strict';

import * as config from 'luci.honk.config';

export const DEFAULT_DIRECT = 'udp://223.5.5.5:53';
export const DEFAULT_PROXY = 'https://cloudflare-dns.com/dns-query';
export const DEFAULT_BIND = 'tcp+udp://127.0.0.1:1053';

function upstream_value(body, name) {
	const parsed = config.parse(body);
	if (!parsed[0]) return null;
	const upstream = parsed[0].byName.upstream?.[0];
	if (!upstream) return null;
	for (let entry in config.named_entries(config.section_body(body, upstream))) {
		if (entry.name !== name) continue;
		let value = replace(entry.value, /\s*->\s*[A-Za-z0-9_.-]+\s*$/, '');
		return config.unquote(config.trim_value(value));
	}
	return null;
}

export function current(content) {
	const found = config.section(content, 'dns');
	const body = found[0] ? config.section_body(content, found[0]) : '';
	const values = config.key_values(body);
	return {
		bind: values.bind || '',
		direct: upstream_value(body, 'direct-dns') || DEFAULT_DIRECT,
		proxy: upstream_value(body, 'proxy-dns') || DEFAULT_PROXY,
	};
}

function update_bind_body(body, value) {
	let lines = [], changed = false;
	for (let line in split(body || '', '\n')) {
		const found = match(line, /^(\s*)bind(\s*:\s*)[^\n]*$/);
		if (!found) {
			push(lines, line);
			continue;
		}
		changed = true;
		if (value) push(lines, `${found[1]}bind${found[2]}${config.daequote(value)}`);
	}
	if (changed) return join('\n', lines);
	if (!value) return body;
	const trailing = match(body || '', /(\s*)$/)?.[1] || '';
	const head = substr(body || '', 0, length(body || '') - length(trailing));
	return `${head}${head ? '\n' : ''}\tbind: ${config.daequote(value)}${trailing || '\n'}`;
}

// Keep the listener state in config.dae in sync with the UCI toggle.  A
// disabled listener has no bind key at all, matching Honk's native default.
export function set_bind(content, enabled) {
	const value = enabled === true ? DEFAULT_BIND : '';
	const found = config.section(content, 'dns');
	if (found[1]) return [null, found[1]];
	if (!found[0]) {
		if (!value) return [content, null];
		return config.replace_section(content, 'dns', `dns {\n\tbind: ${config.daequote(value)}\n}`);
	}
	const body = update_bind_body(config.section_body(content, found[0]), value);
	const section = found[0];
	return [`${substr(content, 0, section.start)}dns {${body}}${substr(content, section.finish + 1)}`, null];
}

function valid_uri(value) {
	return type(value) === 'string' && length(value) <= 512 && match(value, /^[A-Za-z0-9+.-]+:\/\/[^[:space:]]+$/);
}

export function render(mode, options) {
	options = type(options) === 'object' ? options : {};
	const bind = options.bind != null ? config.trim_value(options.bind) : DEFAULT_BIND;
	const direct = config.trim_value(options.direct || DEFAULT_DIRECT);
	const proxy = config.trim_value(options.proxy || DEFAULT_PROXY);
	if (bind && !valid_uri(bind)) return [null, 'DNS_BIND_INVALID', null];
	if (!valid_uri(direct)) return [null, 'DIRECT_DNS_INVALID', null];
	if (!valid_uri(proxy)) return [null, 'PROXY_DNS_INVALID', null];
	let rules;
	switch (mode) {
	case 'china-direct':
		rules = [ '\t\t\tqname(geosite: cn) -> direct-dns', '\t\t\tfallback: proxy-dns' ];
		break;
	case 'gfwlist':
		rules = [ '\t\t\tqname(geosite: gfw) -> proxy-dns', '\t\t\tfallback: direct-dns' ];
		break;
	case 'china-proxy':
		rules = [ '\t\t\tqname(geosite: cn) -> proxy-dns', '\t\t\tfallback: direct-dns' ];
		break;
	case 'global':
		rules = [ '\t\t\tfallback: proxy-dns' ];
		break;
	default:
		return [null, 'MODE_UNKNOWN', null];
	}
	let lines = [ 'dns {' ];
	if (bind) push(lines, `\tbind: ${config.daequote(bind)}`);
	push(lines, '\tupstream {');
	push(lines, `\t\tdirect-dns: ${config.daequote(direct)}`);
	push(lines, `\t\tproxy-dns: ${config.daequote(proxy)} -> honk-proxy`);
	push(lines, '\t}');
	push(lines, '\trouting {');
	push(lines, '\t\trequest {');
	for (let line in rules) push(lines, line);
	push(lines, '\t\t}');
	push(lines, '\t\tresponse {');
	push(lines, '\t\t\tfallback: accept');
	push(lines, '\t\t}');
	push(lines, '\t}');
	push(lines, '}');
	return [join('\n', lines), null, rules];
}
