// SPDX-License-Identifier: Apache-2.0
'use strict';

import * as config from 'luci.honk.config';
import * as dns from 'luci.honk.dns';

function fail(message) {
	print(`FAIL: ${message}\n`);
	exit(1);
}

const expected = {
	'china-direct': 'qname(geosite: cn) -> direct-dns',
	gfwlist: 'qname(geosite: gfw) -> proxy-dns',
	'china-proxy': 'qname(geosite: cn) -> proxy-dns',
	global: 'fallback: proxy-dns',
};

let modes = {}, checks = 0;
for (let name, rule in expected) {
	const rendered = dns.render(name, {
		bind: 'tcp+udp://127.0.0.1:1053',
		direct: 'udp://223.5.5.5:53',
		proxy: 'https://cloudflare-dns.com/dns-query',
	});
	if (!rendered[0]) fail(`${name} did not render: ${rendered[1]}`);
	if (index(rendered[0], rule) < 0) fail(`${name} rule missing`);
	if (!config.parse(rendered[0])[0]) fail(`${name} output does not parse`);
	modes[name] = rendered[2];
	checks += 3;
}

const redacted = config.redact('https://user:password@example.invalid/list?token=SECRET_TOKEN');
if (index(redacted, 'password') >= 0 || index(redacted, 'SECRET_TOKEN') >= 0) fail('sensitive URI data was not redacted');
checks++;

print(sprintf('%J', { ok: true, checks, modes }), '\n');
