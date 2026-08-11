// SPDX-License-Identifier: Apache-2.0
'use strict';

import { readfile, writefile } from 'fs';
import * as config from 'luci.honk.config';
import * as mode from 'luci.honk.mode';
import * as node from 'luci.honk.node';

function fail(message) {
	print(`FAIL: ${message}\n`);
	exit(1);
}

const fixture = ARGV[0];
const output_dir = ARGV[1];
if (!fixture) fail('fixture path is required');

const content = readfile(fixture);
if (type(content) !== 'string' || !content) fail('fixture could not be read');

const catalog = node.catalog(content);
if (length(catalog.nodes) !== 1 || catalog.nodes[0].name !== 'fixture-node') fail('node catalog changed');
if (length(catalog.subscriptions) !== 1 || catalog.subscriptions[0].name !== 'fixture-sub') fail('subscription catalog changed');
if (catalog.subscriptions[0].url != null) fail('subscription URL leaked into catalog');

const runtime_selection = node.select(content, {
	nodeNames: [ '节点 A | 01' ],
	subscriptionNames: [],
	runtimeNodeNames: [ '节点 A | 01' ],
});
if (!runtime_selection[0] || runtime_selection[0].nodes[0] !== '节点 A | 01') fail('UTF-8 runtime node selection changed');

let candidates = {}, checks = 4;
for (let name in [ 'china-direct', 'gfwlist', 'china-proxy', 'global' ]) {
	const compiled = mode.compile(content, {
		mode: name,
		nodeNames: [ 'fixture-node' ],
		subscriptionNames: [],
		deviceRules: [],
	});
	if (!compiled[0]) fail(`${name} did not compile: ${compiled[1]}`);
	const candidate = compiled[0].candidate;
	const parsed = config.parse(candidate);
	if (!parsed[0]) fail(`${name} candidate did not parse: ${parsed[1]}`);
	if (index(candidate, '# legacy comments outside managed sections remain available to migration') < 0) fail(`${name} removed comments`);
	if (index(candidate, 'cache_file {') < 0) fail(`${name} removed unknown sections`);
	if (index(candidate, `# luci-app-honk managed: v1 mode=${name}`) < 0) fail(`${name} marker missing`);
	if (output_dir && !writefile(`${output_dir}/${name}.dae`, candidate)) fail(`${name} output could not be written`);
	candidates[name] = { bytes: length(candidate), revision: config.revision(candidate) };
	checks += 4;
}

print(sprintf('%J', { ok: true, checks, modes: candidates }), '\n');
