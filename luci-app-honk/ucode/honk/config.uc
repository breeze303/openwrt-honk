// SPDX-License-Identifier: Apache-2.0
'use strict';

import { access, chmod, mkdir, popen, readfile, unlink, writefile } from 'fs';

export const CONFIG = getenv('HONK_CONFIG_PATH') || '/etc/honk/config.dae';
export const DEFAULT_CONFIG = getenv('HONK_DEFAULT_CONFIG_PATH') || '/etc/honk/config.dae.default';
export const BACKUP = getenv('HONK_BACKUP_PATH') || '/etc/honk/config.dae.last-good';
export const RUN_DIR = getenv('HONK_RUN_DIR') || '/run/honk';
export const HONK_TOOL = getenv('HONK_TOOL_PATH') || '/usr/bin/honk-tool';
export const MAX_BYTES = 1024 * 1024;

export function trim_value(value) {
	return trim(sprintf('%s', value ?? ''));
}

export function is_bool(value) {
	return type(value) === 'bool';
}

export function shellquote(value) {
	return `'${replace(sprintf('%s', value ?? ''), "'", "'\\''")}'`;
}

export function daequote(value) {
	let escaped = replace(sprintf('%s', value ?? ''), /\\/g, '\\\\');
	escaped = replace(escaped, /'/g, "\\'");
	return `'${escaped}'`;
}

export function unquote(value) {
	value = trim_value(value);
	if (length(value) >= 2) {
		const first = substr(value, 0, 1);
		const last = substr(value, length(value) - 1, 1);
		if ((first === "'" && last === "'") || (first === '"' && last === '"'))
			return substr(value, 1, length(value) - 2);
	}
	return value;
}

export function read(path) {
	return readfile(path || CONFIG) || '';
}

export function read_default() {
	return readfile(DEFAULT_CONFIG) || '';
}

export function result_error(code, message, extra) {
	let result = { ok: false, error: { code, message: message || code || 'operation failed' } };
	for (let key, value in extra || {})
		result[key] = value;
	return result;
}

function section_close(content, open) {
	let depth = 1, quote = null, escaped = false, comment = false;
	for (let index = open + 1; index < length(content); index++) {
		const chr = substr(content, index, 1);
		if (comment) {
			if (chr === '\n') comment = false;
		}
		else if (quote) {
			if (escaped) escaped = false;
			else if (chr === '\\') escaped = true;
			else if (chr === quote) quote = null;
		}
		else if (chr === '#') comment = true;
		else if (chr === "'" || chr === '"') quote = chr;
		else if (chr === '{') depth++;
		else if (chr === '}') {
			depth--;
			if (depth === 0) return index;
		}
	}
	return null;
}

function line_end(content, offset) {
	const relative = index(substr(content, offset), '\n');
	return relative < 0 ? -1 : offset + relative;
}

export function parse(content) {
	if (type(content) !== 'string') return [null, 'configuration must be text'];
	let sections = [], by_name = {}, offset = 0;
	while (offset < length(content)) {
		let searching = true;
		while (searching && offset < length(content)) {
			const chr = substr(content, offset, 1);
			if (match(chr, /\s/)) offset++;
			else if (chr === '#') {
				const newline = line_end(content, offset);
				offset = newline >= 0 ? newline + 1 : length(content);
			}
			else searching = false;
		}
		if (offset >= length(content)) break;
		const head = match(substr(content, offset), /^([A-Za-z_][A-Za-z0-9_-]*)/);
		if (!head) return [null, `unsupported top-level token at byte ${offset + 1}`];
		const name = head[1];
		let open = offset + length(name);
		while (open < length(content) && match(substr(content, open, 1), /\s/)) open++;
		if (substr(content, open, 1) !== '{')
			return [null, `section ${name} is missing an opening brace`];
		const close = section_close(content, open);
		if (close == null) return [null, `section ${name} is missing a closing brace`];
		const section = { name, start: offset, open, close, finish: close };
		push(sections, section);
		by_name[name] = by_name[name] || [];
		push(by_name[name], section);
		offset = close + 1;
	}
	return [{ content, sections, byName: by_name }, null];
}

// Child names use the source-name grammar, which also permits dots and a
// leading digit. Flat entries remain untouched.
export function nested_sections(content) {
	if (type(content) !== 'string') return [null, 'configuration must be text'];
	let sections = [], offset = 0;
	while (offset < length(content)) {
		const chr = substr(content, offset, 1);
		if (match(chr, /\s/)) {
			offset++;
		}
		else if (chr === '#') {
			const newline = line_end(content, offset);
			offset = newline >= 0 ? newline + 1 : length(content);
		}
		else {
			const head = match(substr(content, offset), /^([A-Za-z0-9_.-]+)/);
			const name = head?.[1];
			let open = name ? offset + length(name) : offset;
			while (name && open < length(content) && match(substr(content, open, 1), /\s/)) open++;
			if (name && substr(content, open, 1) === '{') {
				const close = section_close(content, open);
				if (close == null) return [null, `section ${name} is missing a closing brace`];
				push(sections, { name, start: offset, open, close, finish: close });
				offset = close + 1;
			}
			else {
				const newline = line_end(content, offset);
				offset = newline >= 0 ? newline + 1 : length(content);
			}
		}
	}
	return [sections, null];
}

export function section(content, name) {
	const parsed = parse(content);
	if (!parsed[0]) return [null, parsed[1]];
	const list = parsed[0].byName[name] || [];
	if (length(list) > 1) return [null, `duplicate ${name} section`];
	return [list[0] || null, null];
}

export function section_body(content, entry) {
	return entry ? substr(content, entry.open + 1, entry.close - entry.open - 1) : '';
}

function strip_comment(line) {
	let quote = null, escaped = false;
	for (let index = 0; index < length(line); index++) {
		const chr = substr(line, index, 1);
		if (quote) {
			if (escaped) escaped = false;
			else if (chr === '\\') escaped = true;
			else if (chr === quote) quote = null;
		}
		else if (chr === "'" || chr === '"') quote = chr;
		else if (chr === '#') return substr(line, 0, index);
	}
	return line;
}

export function key_values(body) {
	let result = {};
	for (let line in split(sprintf('%s', body || ''), '\n')) {
		line = strip_comment(line);
		const entry = match(line, /^\s*([A-Za-z0-9_.-]+)\s*:\s*(.*?)\s*$/);
		if (entry && entry[2] != null) result[entry[1]] = unquote(entry[2]);
	}
	return result;
}

export function named_entries(body) {
	let result = [];
	for (let line in split(sprintf('%s', body || ''), '\n')) {
		line = strip_comment(line);
		const entry = match(line, /^\s*([A-Za-z0-9_.-]+)\s*:\s*(.*?)\s*$/);
		if (entry && entry[2] != null) push(result, { name: entry[1], value: unquote(entry[2]) });
	}
	return result;
}

export function ensure_key(body, key, value) {
	if (key_values(body)[key] != null) return body;
	const trailing = match(body || '', /(\s*)$/)?.[1] || '';
	const head = substr(body || '', 0, length(body || '') - length(trailing));
	return `${head}${head ? '\n' : ''}\t${key}: ${daequote(value)}${trailing}`;
}

export function replace_section(content, name, block) {
	const found = section(content, name);
	if (found[1]) return [null, found[1]];
	if (!found[0]) {
		const prefix = rtrim(content || '');
		return [`${prefix}${prefix ? '\n\n' : ''}${block}\n`, null];
	}
	const entry = found[0];
	return [`${substr(content, 0, entry.start)}${block}${substr(content, entry.finish + 1)}`, null];
}

export function replace_nested_section(content, outer_name, nested_name, block) {
	const outer_result = section(content, outer_name);
	if (outer_result[1]) return [null, outer_result[1]];
	if (!outer_result[0])
		return replace_section(content, outer_name, `${outer_name} {\n${block}\n}`);
	const outer = outer_result[0];
	const body = section_body(content, outer);
	const nested_result = section(body, nested_name);
	if (nested_result[1]) return [null, nested_result[1]];
	let updated;
	if (nested_result[0]) {
		const nested = nested_result[0];
		updated = `${substr(body, 0, nested.start)}${block}${substr(body, nested.finish + 1)}`;
	}
	else {
		const trailing = match(body, /(\s*)$/)?.[1] || '';
		const head = substr(body, 0, length(body) - length(trailing));
		updated = `${head}${head ? '\n\n' : '\n'}${block}${trailing}`;
	}
	const outer_block = `${outer_name} {${updated}}`;
	return [`${substr(content, 0, outer.start)}${outer_block}${substr(content, outer.finish + 1)}`, null];
}

export function replace_managed(content, blocks, marker) {
	const parsed = parse(content);
	if (!parsed[0]) return [null, parsed[1]];
	const managed = { global: true, group: true, routing: true, dns: true };
	for (let name in managed)
		if (length(parsed[0].byName[name] || []) > 1) return [null, `duplicate ${name} section`];
	let kept = [], cursor = 0;
	for (let entry in parsed[0].sections) {
		if (managed[entry.name]) {
			push(kept, substr(content, cursor, entry.start - cursor));
			cursor = entry.finish + 1;
		}
	}
	push(kept, substr(content, cursor));
	let preserved = join('', kept);
	preserved = replace(preserved, /[^\n]*luci-app-honk\s+managed:[^\n]*\n?/g, '');
	preserved = trim_value(preserved);
	let result = `${marker}\n${join('\n\n', blocks)}`;
	if (preserved) result += `\n\n${preserved}`;
	return [`${result}\n`, null];
}

export function ensure_run_dir() {
	if (!access(RUN_DIR) && !mkdir(RUN_DIR) && !access(RUN_DIR)) return false;
	chmod(RUN_DIR, 0700);
	return true;
}

export function file_revision(path) {
	const fd = popen(`/usr/bin/sha256sum ${shellquote(path || CONFIG)} 2>/dev/null`, 'r');
	const output = fd?.read?.('all') || '';
	fd?.close();
	return match(output, /^([0-9a-fA-F]+)/)?.[1] || '';
}

export function revision(content) {
	if (!ensure_run_dir()) return '';
	const path = `${RUN_DIR}/luci-revision-${time()}-${length(content || '')}`;
	if (!writefile(path, content || '')) return '';
	chmod(path, 0600);
	const value = file_revision(path);
	unlink(path);
	return value;
}

export function redact(value) {
	value = sprintf('%s', value ?? '');
	value = replace(value, /([A-Za-z0-9+.-]+:\/\/)[^@[:space:]]+@/g, '$1***@');
	value = replace(value, /([?&])([A-Za-z0-9_-]+)=([^&#[:space:]]+)/g, (all, prefix, key, secret) => {
		const lower = lc(key);
		return (lower in { token: true, key: true, password: true, secret: true, auth: true }) ? `${prefix}${key}=***` : `${prefix}${key}=${secret}`;
	});
	value = replace(value, /([Pp]assword\s*[:=]\s*)[^[:space:],]+/g, '$1***');
	value = replace(value, /([Ss]ecret\s*[:=]\s*)[^[:space:],]+/g, '$1***');
	return replace(value, /([Tt]oken\s*[:=]\s*)[^[:space:],]+/g, '$1***');
}

export function candidate_path(content, purpose) {
	if (!ensure_run_dir()) return null;
	const digest = revision(content || '');
	if (!digest || !match(purpose || 'candidate', /^[A-Za-z0-9_-]{1,32}$/)) return null;
	return `${RUN_DIR}/luci-${purpose || 'candidate'}-${substr(digest, 0, 20)}.dae`;
}

export function validate(content) {
	if (type(content) !== 'string') return [false, 'configuration must be text', null];
	if (length(content) > MAX_BYTES) return [false, 'configuration exceeds 1 MiB', null];
	const path = candidate_path(content, 'validate');
	if (!path || !writefile(path, content)) return [false, 'temporary configuration could not be written', null];
	chmod(path, 0600);
	const fd = popen(`${shellquote(HONK_TOOL)} validate --config ${shellquote(path)} --json 2>&1`, 'r');
	const output = fd?.read?.('all') || '';
	const code = fd ? fd.close() : 127;
	unlink(path);
	let decoded = null;
	try { decoded = json(output); } catch (e) { /* keep validator output */ }
	return [code === 0, redact(trim_value(output)), decoded];
}

export function write_candidate(content, purpose) {
	if (type(content) !== 'string' || length(content) > MAX_BYTES) return [null, 'CONFIG_INVALID'];
	const path = candidate_path(content, purpose || 'candidate');
	if (!path || !writefile(path, content) || !chmod(path, 0600)) {
		if (path) unlink(path);
		return [null, 'WRITE_FAILED'];
	}
	return [path, null];
}
