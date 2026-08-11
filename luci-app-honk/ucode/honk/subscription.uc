// SPDX-License-Identifier: Apache-2.0
'use strict';

import { access, chmod, mkdir, popen, readfile, unlink, writefile } from 'fs';
import { cursor } from 'uci';
import * as config from 'luci.honk.config';

export const CACHE_DIR = getenv('HONK_SUBSCRIPTION_CACHE_DIR') || '/etc/honk/subscriptions';

function cache_ttl() {
	const configured = int(getenv('HONK_SUBSCRIPTION_CACHE_TTL'));
	if (configured != null) return configured < 0 ? 0 : configured;
	const uci = cursor();
	const value = int(uci.get('honk', 'main', 'subscription_cache_ttl'));
	uci.unload();
	return value != null && value >= 0 ? value : 604800;
}

export function safe_name(name) {
	if (type(name) !== 'string' || length(name) < 1 || length(name) > 64 || !match(name, /^[A-Za-z0-9_.-]+$/) || name === '.' || name === '..') return null;
	return name;
}

function paths(name) {
	const safe = safe_name(name);
	return safe ? { raw: `${CACHE_DIR}/${safe}.sub`, meta: `${CACHE_DIR}/${safe}.json` } : null;
}

function ensure_dir() {
	if (!access(CACHE_DIR) && !mkdir(CACHE_DIR) && !access(CACHE_DIR)) return false;
	chmod(CACHE_DIR, 0700);
	return true;
}

function now_iso() {
	const fd = popen('/bin/date -u +%Y-%m-%dT%H:%M:%SZ', 'r');
	const value = trim(fd?.read?.('all') || '');
	fd?.close();
	return value || null;
}

function read_record(name) {
	const target = paths(name);
	if (!target) return null;
	let record;
	try { record = json(readfile(target.meta) || ''); } catch (e) { return null; }
	if (type(record) !== 'object') return null;
	if (type(record.nodes) !== 'array') record.nodes = [];
	const updated = int(record.updatedEpoch) || 0;
	const missing = updated <= 0 || !length(record.nodes);
	record.nodeCount = missing ? 0 : (int(record.nodeCount) || length(record.nodes));
	record.stale = !missing && time() - updated > cache_ttl();
	record.source = missing ? 'missing' : (record.stale ? 'stale' : 'cache');
	return record;
}

function raw_fetch(url, target) {
	const command = `/usr/bin/curl -fsSL --max-filesize 1048576 --connect-timeout 10 --max-time 30 --user-agent ${config.shellquote('Honk/0.0.1')} -o ${config.shellquote(target)} ${config.shellquote(url)} 2>/dev/null`;
	return system(command) === 0 && access(target);
}

function tool_nodes(source, payload_file) {
	let command = `${config.shellquote(config.HONK_TOOL)} sub --format json`;
	if (payload_file) command += ` --payload-file ${config.shellquote(payload_file)}`;
	command += ` ${config.shellquote(source)} 2>&1`;
	const fd = popen(command, 'r');
	const output = fd?.read?.('all') || '';
	fd?.close();
	const start = index(output, '[');
	if (start < 0) return [null, 'subscription parse failed'];
	let items;
	try { items = json(substr(output, start)); } catch (e) { return [null, 'subscription parse failed']; }
	if (type(items) !== 'array') return [null, 'subscription parse failed'];
	let normalized = [];
	for (let item in items) {
		if (type(item) !== 'object' || type(item.name) !== 'string' || !item.name || length(item.name) > 256) continue;
		push(normalized, {
			name: item.name,
			protocol: lc(sprintf('%s', item.protocol || 'unknown')),
			address: item.address,
			host: item.host,
			port: int(item.port),
		});
	}
	if (!length(normalized)) return [null, 'no supported nodes found'];
	normalized = sort(normalized, (left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
	return [normalized, null];
}

function write_atomic(path, value) {
	const temporary = `${path}.tmp-${time()}-${length(value || '')}`;
	if (!writefile(temporary, value) || !chmod(temporary, 0600)) { unlink(temporary); return false; }
	const moved = system(`/bin/mv -f ${config.shellquote(temporary)} ${config.shellquote(path)}`) === 0;
	if (!moved) unlink(temporary);
	return moved;
}

function sha256(path) {
	const fd = popen(`/usr/bin/sha256sum ${config.shellquote(path)} 2>/dev/null`, 'r');
	const output = fd?.read?.('all') || '';
	fd?.close();
	return match(output, /^([0-9a-fA-F]+)/)?.[1] || '';
}

function record_error(name, detail) {
	const target = paths(name);
	if (!target) return;
	let record = read_record(name) || { name, nodeCount: 0, nodes: [], updatedEpoch: 0 };
	record.lastError = config.redact(detail || 'subscription refresh failed');
	record.lastErrorAt = now_iso();
	if (record.source === 'missing') { record.stale = false; record.source = 'missing'; }
	write_atomic(target.meta, sprintf('%J', record));
}

export function refresh(name, url) {
	const target = paths(name);
	if (!target || type(url) !== 'string' || !url || length(url) > 4096) return [null, 'invalid subscription'];
	if (!ensure_dir() || !config.ensure_run_dir()) return [null, 'subscription cache directory is unavailable'];
	const raw_temp = `${config.RUN_DIR}/luci-subscription-${name}-${time()}`;
	unlink(raw_temp);
	let source = raw_temp, payload_file = null, raw_content = '';
	if (match(url, /^https?:\/\//)) {
		if (!raw_fetch(url, raw_temp)) {
			unlink(raw_temp);
			record_error(name, 'subscription download failed');
			return [null, 'subscription download failed'];
		}
		raw_content = readfile(raw_temp) || '';
		source = url;
		payload_file = raw_temp;
	}
	else {
		if (!match(url, /^[A-Za-z0-9+.-]+:\/\//)) {
			record_error(name, 'unsupported subscription link');
			return [null, 'unsupported subscription link'];
		}
		raw_content = `${url}\n`;
		if (!writefile(raw_temp, raw_content)) {
			record_error(name, 'subscription staging failed');
			return [null, 'subscription staging failed'];
		}
		chmod(raw_temp, 0600);
	}
	const parsed = tool_nodes(source, payload_file);
	unlink(raw_temp);
	if (!parsed[0]) { record_error(name, parsed[1]); return [null, config.redact(parsed[1])]; }
	if (!raw_content) { record_error(name, 'subscription is empty'); return [null, 'subscription is empty']; }
	const now = time();
	let record = { name, nodeCount: length(parsed[0]), nodes: parsed[0], updatedEpoch: now, updatedAt: now_iso(), lastError: null };
	if (!write_atomic(target.raw, raw_content)) { record_error(name, 'subscription cache write failed'); return [null, 'subscription cache write failed']; }
	record.sha256 = sha256(target.raw);
	if (!write_atomic(target.meta, sprintf('%J', record))) { record_error(name, 'subscription metadata write failed'); return [null, 'subscription metadata write failed']; }
	return [record, null];
}

export function cache(name) {
	return read_record(name);
}

export function remove(name) {
	const target = paths(name);
	if (!target) return false;
	unlink(target.raw);
	unlink(target.meta);
	return true;
}

function same_nodes(current, observed) {
	if (length(current) !== length(observed)) return false;
	for (let index = 0; index < length(current); index++)
		if (current[index].name !== observed[index].name || current[index].protocol !== observed[index].protocol) return false;
	return true;
}

export function capture_runtime(catalog, runtime_nodes) {
	if (type(catalog) !== 'object' || type(runtime_nodes) !== 'array' || !ensure_dir()) return false;
	let configured = {}, observed = {};
	for (let item in catalog.subscriptions || []) {
		if (type(item) === 'object' && safe_name(item.name) && item.enabled !== false) { configured[item.name] = true; observed[item.name] = []; }
	}
	for (let item in runtime_nodes) {
		if (type(item) !== 'object' || !configured[item.subscription] || type(item.name) !== 'string' || !item.name) continue;
		push(observed[item.subscription], { name: item.name, protocol: lc(sprintf('%s', item.protocol || 'unknown')) });
	}
	let changed = false;
	for (let name, nodes in observed) {
		if (!length(nodes)) continue;
		nodes = sort(nodes, (left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
		let record = read_record(name) || { name, nodes: [], nodeCount: 0, updatedEpoch: 0 };
		if (!same_nodes(record.nodes || [], nodes)) {
			record.nodes = nodes;
			record.nodeCount = length(nodes);
			record.updatedEpoch = time();
			record.updatedAt = now_iso();
			record.snapshot = 'runtime';
			record.source = null;
			record.stale = null;
			if (write_atomic(paths(name).meta, sprintf('%J', record))) changed = true;
		}
	}
	return changed;
}

export function catalog_nodes(catalog) {
	let cached_nodes = [];
	for (let item in catalog.subscriptions || []) {
		const record = read_record(item.name);
		if (!record) continue;
		item.cacheSource = record.source;
		item.cachedAt = record.updatedAt;
		item.cachedNodeCount = record.nodeCount || length(record.nodes);
		item.cachedError = record.lastError;
		item.cachedErrorAt = record.lastErrorAt;
		for (let cached in record.nodes)
			push(cached_nodes, { name: cached.name, protocol: cached.protocol || 'unknown', subscription: item.name, source: record.source });
	}
	cached_nodes = sort(cached_nodes, (left, right) => left.name < right.name ? -1 : left.name > right.name ? 1 : 0);
	return cached_nodes;
}
