// SPDX-License-Identifier: Apache-2.0
'use strict';

import * as network from 'luci.honk.network';

function fail(message) {
	print(`FAIL: ${message}\n`);
	exit(1);
}

function fixture(mode) {
	let lan_l3 = mode === 'no-l3' ? '' : 'br-lan';
	let wan_l3 = mode === 'same-device' ? 'br-lan' : (mode === 'missing-wan' ? '' : 'eth0.2');
	let lan_addresses = mode === 'ipv6-only' ? [] : [ { address: '192.168.8.1', mask: 24 } ];
	let wan_routes = mode === 'missing-wan' ? [] : [ { target: '0.0.0.0', metric: 10 } ];
	if (mode === 'duplicate-route') push(wan_routes, { target: '0.0.0.0', metric: 20 });
	return [{ interface: [
		{ interface: 'lan', l3_device: lan_l3, device: 'br-lan', 'ipv4-address': lan_addresses, 'ipv6-address': [ { address: 'fd00::1', mask: 64 } ], route: [] },
		{ interface: 'wan', l3_device: wan_l3, device: 'eth0.2', 'ipv4-address': [ { address: '198.51.100.2', mask: 24 } ], 'ipv6-address': [], route: wan_routes },
	] }, {
		'br-lan': { present: true, up: true, bridge: true, parent: 'eth0' },
		'eth0.2': { present: true, up: true, parent: 'eth0' },
	}];
}

let checks = 0;
for (let mode in [ 'happy', 'same-device', 'no-l3', 'missing-wan', 'duplicate-route', 'ipv6-only' ]) {
	const input = fixture(mode);
	const result = network.inspect(input[0], input[1]);
	if (!result.ok || length(result.interfaces) !== 2) fail(`${mode} interface normalization failed`);
	if (mode === 'happy') {
		if (result.recommended.lan !== 'br-lan' || result.recommended.wan !== 'eth0.2' || result.ambiguous) fail('happy recommendation changed');
		if (result.interfaces[1].defaultRoute.metric !== 10) fail('default route metric changed');
	}
	else if (mode === 'same-device' && !result.ambiguous) fail('same device accepted');
	else if (mode === 'no-l3' && index(result.interfaces[0].reasonCodes, 'L3_DEVICE_MISSING') < 0) fail('missing L3 reason changed');
	else if (mode === 'missing-wan' && (!result.ambiguous || result.recommended.wan != null)) fail('missing WAN accepted');
	else if (mode === 'duplicate-route' && index(result.interfaces[1].reasonCodes, 'MULTIPLE_DEFAULT_ROUTES') < 0) fail('multiple routes reason changed');
	else if (mode === 'ipv6-only' && result.interfaces[0].addresses[0].family !== 'ipv6') fail('IPv6 normalization changed');
	checks += 2;
}

print(sprintf('%J', { ok: true, checks, scenarios: 6 }), '\n');
