'use strict';
'require view';
'require rpc';

const PROTOCOL_VERSION = 1;
const RESOURCE = '/luci-static/resources/honk/app/index.html';

const calls = Object.freeze({
	state: rpc.declare({ object: 'luci.honk', method: 'state' }),
	advanced: rpc.declare({ object: 'luci.honk', method: 'advanced' }),
	default_config: rpc.declare({ object: 'luci.honk', method: 'default_config' }),
	diagnostics: rpc.declare({ object: 'luci.honk', method: 'diagnostics' }),
	logs: rpc.declare({ object: 'luci.honk', method: 'logs' }),
	network_interfaces: rpc.declare({ object: 'luci.honk', method: 'network_interfaces' }),
	runtime_dashboard: rpc.declare({ object: 'luci.honk', method: 'runtime_dashboard' }),
	preview: rpc.declare({ object: 'luci.honk', method: 'preview', params: [ 'mode', 'nodeNames', 'subscriptionNames', 'deviceRules', 'expectedRevision', 'takeover', 'directDns', 'proxyDns' ] }),
	apply: rpc.declare({ object: 'luci.honk', method: 'apply', params: [ 'mode', 'nodeNames', 'subscriptionNames', 'deviceRules', 'expectedRevision', 'takeover', 'directDns', 'proxyDns' ] }),
	service: rpc.declare({ object: 'luci.honk', method: 'service', params: [ 'action' ] }),
	sources: rpc.declare({ object: 'luci.honk', method: 'sources', params: [ 'action', 'name', 'url', 'updateInterval', 'expectedRevision' ] }),
	validate_advanced: rpc.declare({ object: 'luci.honk', method: 'validate_advanced', params: [ 'config' ] }),
	apply_advanced: rpc.declare({ object: 'luci.honk', method: 'apply_advanced', params: [ 'config', 'expectedRevision' ] }),
	refresh_subscription: rpc.declare({ object: 'luci.honk', method: 'refresh_subscription', params: [ 'name' ] }),
	subscription_cache: rpc.declare({ object: 'luci.honk', method: 'subscription_cache', params: [ 'name' ] }),
	delete_subscription_cache: rpc.declare({ object: 'luci.honk', method: 'delete_subscription_cache', params: [ 'name' ] }),
	delay: rpc.declare({ object: 'luci.honk', method: 'delay', params: [ 'name' ] }),
	connectivity: rpc.declare({ object: 'luci.honk', method: 'connectivity', params: [ 'id' ] }),
	clear_logs: rpc.declare({ object: 'luci.honk', method: 'clear_logs' }),
	toggle_clash_api: rpc.declare({ object: 'luci.honk', method: 'toggle_clash_api', params: [ 'enabled', 'expectedRevision' ] }),
	reset_config: rpc.declare({ object: 'luci.honk', method: 'reset_config', params: [ 'expectedRevision' ] }),
	apply_interfaces: rpc.declare({ object: 'luci.honk', method: 'apply_interfaces', params: [ 'lanDevice', 'wanDevice', 'lan', 'wan', 'dialMode', 'logLevel', 'dnsmasqForwarding', 'proxyLocalDns', 'expectedRevision' ] }),
	runtime_prepare: rpc.declare({ object: 'luci.honk', method: 'runtime_prepare', params: [ 'expectedRevision' ] }),
});

const paramKeys = Object.freeze({
	state: [], advanced: [], default_config: [], diagnostics: [], logs: [], network_interfaces: [], runtime_dashboard: [], clear_logs: [],
	preview: [ 'mode', 'nodeNames', 'subscriptionNames', 'deviceRules', 'expectedRevision', 'takeover', 'directDns', 'proxyDns' ],
	apply: [ 'mode', 'nodeNames', 'subscriptionNames', 'deviceRules', 'expectedRevision', 'takeover', 'directDns', 'proxyDns' ],
	service: [ 'action' ],
	sources: [ 'action', 'name', 'url', 'updateInterval', 'expectedRevision' ],
	validate_advanced: [ 'config' ], apply_advanced: [ 'config', 'expectedRevision' ],
	refresh_subscription: [ 'name' ], subscription_cache: [ 'name' ], delete_subscription_cache: [ 'name' ], delay: [ 'name' ], connectivity: [ 'id' ],
	toggle_clash_api: [ 'enabled', 'expectedRevision' ], reset_config: [ 'expectedRevision' ],
	apply_interfaces: [ 'lanDevice', 'wanDevice', 'lan', 'wan', 'dialMode', 'logLevel', 'dnsmasqForwarding', 'proxyLocalDns', 'expectedRevision' ],
	runtime_prepare: [ 'expectedRevision' ],
});

function bridgeError(code, message) {
	return { code, message };
}

function validRequest(data) {
	if (!data || typeof data !== 'object' || Array.isArray(data)) return false;
	if (data.type !== 'honk-bridge-request' || data.version !== PROTOCOL_VERSION) return false;
	if (typeof data.requestId !== 'string' || !/^[A-Za-z0-9_-]{1,96}$/.test(data.requestId)) return false;
	if (typeof data.method !== 'string' || !Object.prototype.hasOwnProperty.call(calls, data.method)) return false;
	if (!data.params || typeof data.params !== 'object' || Array.isArray(data.params)) return false;
	return Object.keys(data.params).every(key => paramKeys[data.method].includes(key));
}

return view.extend({
	render: function() {
		const iframe = E('iframe', {
			class: 'honk-dashboard-frame',
			src: RESOURCE,
			title: _('Honk'),
			style: 'display:block;width:100%;min-height:calc(100vh - 118px);border:0;background:transparent;'
		});
		const expectedOrigin = new URL(RESOURCE, window.location.href).origin;
		const controller = new AbortController();
		const reply = (requestId, payload) => iframe.contentWindow?.postMessage(payload, expectedOrigin);
		const onMessage = event => {
			if (event.origin !== expectedOrigin || event.source !== iframe.contentWindow) return;
			const data = event.data;
			if (data?.type === 'honk-bridge-handshake' && data.version === PROTOCOL_VERSION) {
				reply(null, { type: 'honk-bridge-ready', version: PROTOCOL_VERSION });
				return;
			}
			if (!validRequest(data)) return;
			const args = paramKeys[data.method].map(key => data.params[key]);
			Promise.resolve(calls[data.method](...args)).then(result => {
				reply(data.requestId, { type: 'honk-bridge-response', requestId: data.requestId, result });
			}).catch(error => {
				reply(data.requestId, {
					type: 'honk-bridge-response',
					requestId: data.requestId,
					error: bridgeError('RPC_FAILURE', error?.message || _('The request failed.')),
				});
			});
		};
		window.addEventListener('message', onMessage, { signal: controller.signal });
		const observer = new MutationObserver(() => {
			if (document.documentElement.contains(iframe)) return;
			controller.abort();
			observer.disconnect();
		});
		observer.observe(document.documentElement, { childList: true, subtree: true });
		return E('div', { class: 'cbi-map' }, [ iframe ]);
	},
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,
});
