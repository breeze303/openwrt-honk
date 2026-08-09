export type ApiError = { ok?: boolean; error?: { code?: string; message?: string } }

const base = '/cgi-bin/luci/admin/services/honk-legacy/api'

async function request<T>(path: string, payload?: unknown): Promise<T> {
  const localToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''
  let parentToken = ''
  if (window.parent !== window) {
    try {
      parentToken = window.parent.document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''
    } catch {
      parentToken = ''
    }
  }
  const csrf = localToken || parentToken
  const response = await fetch(`${base}/${path}`, {
    method: payload === undefined ? 'GET' : 'POST',
    credentials: 'same-origin',
    cache: 'no-store',
    headers: payload === undefined ? { Accept: 'application/json' } : {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      ...(csrf ? { 'X-CSRF-Token': csrf } : {}),
    },
    body: payload === undefined ? undefined : JSON.stringify(payload),
  })
  const data = await response.json() as T & ApiError
  if (!response.ok || data.ok === false) {
    throw new Error(data.error?.message || `HTTP ${response.status}`)
  }
  return data
}

export const api = {
	dashboard: () => request<RuntimeBootstrap>('dashboard'),
	dashboardPrepare: () => request<RuntimeBootstrap>('dashboard_prepare', {}),
	state: () => request<StateResponse>('state'),
  validate: (config: string) => request<{ ok: boolean }>('validate', { config }),
  save: (config: string, revision: string) => request<SaveResponse>('save', { config, revision }),
  apply: (config: string, revision: string) => request<SaveResponse>('apply', { config, revision }),
  service: (action: string) => request('service', { action }),
  logs: () => request<{ lines: string }>('logs'),
  traffic: () => request<Record<string, unknown>>('traffic'),
  model: () => request<ModelResponse>('model'),
  runtimeNodes: () => request<RuntimeNodesResponse>('runtime_nodes'),
  modelParse: (config: string) => request<ModelResponse>('model_parse', { config }),
  preview: (config: string) => request<PreviewResponse>('model_preview', { config }),
  modelApply: (config: string, revision: string) => request<SaveResponse>('model_apply', { config, revision }),
  parseNode: (link: string) => request<{ ok: boolean; node: ParsedNode }>('node_parse', { link }),
  testNode: (link: string, options: NodeTestOptions = {}) => request<NodeTestResponse>('node_test', { link, ...options }),
  quickState: () => request<QuickState>('quick_state'),
  networkDiscovery: () => request<NetworkDiscovery>('network_discovery'),
  quickPreview: (input: QuickInput) => request<QuickPreview>('quick_preview', input),
  quickApply: (previewNonce: string, expectedRevision: string) => request<QuickApply>('quick_apply', { previewNonce, expectedRevision }),
}

export type RuntimeBootstrap = {
	ok: boolean
	ready: boolean
	needsMigration: boolean
	running: boolean
	controllerPort: number
	secret: string
	configuredNodeCount?: number
}

export type DelayHistory = { time: string; delay: number }
export type ProxyInfo = {
	name: string
	type: string
	all?: string[]
	now?: string
	history?: DelayHistory[]
	udp?: boolean
}
export type ProxyDocument = { proxies: Record<string, ProxyInfo> }
export type ClashConfig = { mode: string; 'mode-list'?: string[] }
export type ConnectionInfo = {
	id: string
	metadata: {
		network: string
		sourceIP: string
		destinationIP: string
		sourcePort: string
		destinationPort: string
		host: string
	}
	upload: number
	download: number
	start: string
	chains: string[]
	rule: string
	rulePayload: string
}
export type ConnectionsDocument = {
	downloadTotal: number
	uploadTotal: number
	memory: number
	connections: ConnectionInfo[]
}
export type ClashRule = { type?: string; payload?: string; proxy?: string; size?: number }
export type RulesDocument = { rules: ClashRule[] }
export type OutboundStat = {
	name: string
	totalConns: number
	activeConns: number
	upload: number
	download: number
	errors: number
}
export type StatsDocument = { outbounds: OutboundStat[] }
export type TrafficFrame = { up: number; down: number }
export type MemoryFrame = { inuse: number }
export type LogFrame = { type: string; payload: string }

export class ClashClient {
	private readonly origin: string

	constructor(port: number, private readonly secret: string) {
		const rawHost = window.location.hostname
		const host = rawHost.includes(':') && !rawHost.startsWith('[') ? `[${rawHost}]` : rawHost
		this.origin = `${window.location.protocol}//${host}:${port}`
	}

	private async request<T>(path: string, init: RequestInit = {}): Promise<T> {
		const headers = new Headers(init.headers)
		headers.set('Accept', 'application/json')
		if (this.secret) headers.set('Authorization', `Bearer ${this.secret}`)
		if (init.body !== undefined) headers.set('Content-Type', 'application/json')
		const response = await fetch(`${this.origin}${path}`, { ...init, headers, cache: 'no-store' })
		if (!response.ok) {
			const detail = await response.text().catch(() => '')
			throw new Error(detail || `Clash API HTTP ${response.status}`)
		}
		if (response.status === 204) return undefined as T
		return await response.json() as T
	}

	configs = () => this.request<ClashConfig>('/configs')
	proxies = () => this.request<ProxyDocument>('/proxies')
	connections = () => this.request<ConnectionsDocument>('/connections')
	rules = () => this.request<RulesDocument>('/rules')
	stats = () => this.request<StatsDocument>('/stats')

	setMode(mode: string) {
		return this.request<void>('/configs', { method: 'PATCH', body: JSON.stringify({ mode }) })
	}

	selectProxy(group: string, name: string) {
		return this.request<void>(`/proxies/${encodeURIComponent(group)}`, {
			method: 'PUT',
			body: JSON.stringify({ name }),
		})
	}

	testProxy(name: string, url: string, timeout = 8000) {
		const query = new URLSearchParams({ url, timeout: String(timeout) })
		return this.request<{ delay: number }>(`/proxies/${encodeURIComponent(name)}/delay?${query}`)
	}

	testGroup(name: string, url: string, timeout = 8000) {
		const query = new URLSearchParams({ url, timeout: String(timeout) })
		return this.request<Record<string, number>>(`/group/${encodeURIComponent(name)}/delay?${query}`)
	}

	subscriptions() {
		return this.request<SubscriptionDocument>('/subscriptions')
	}

	refreshSubscription(name: string) {
		return this.request<void>(`/subscriptions/${encodeURIComponent(name)}/refresh`, { method: 'POST' })
	}

	closeConnection(id: string) {
		return this.request<void>(`/connections/${encodeURIComponent(id)}`, { method: 'DELETE' })
	}

	closeAllConnections() {
		return this.request<void>('/connections', { method: 'DELETE' })
	}

	async stream<T>(path: string, signal: AbortSignal, onFrame: (frame: T) => void) {
		const headers = new Headers({ Accept: 'application/json' })
		if (this.secret) headers.set('Authorization', `Bearer ${this.secret}`)
		const response = await fetch(`${this.origin}${path}`, { headers, cache: 'no-store', signal })
		if (!response.ok || !response.body) throw new Error(`Clash stream HTTP ${response.status}`)
		const reader = response.body.getReader()
		const decoder = new TextDecoder()
		let buffer = ''
		while (!signal.aborted) {
			const { done, value } = await reader.read()
			if (done) break
			buffer += decoder.decode(value, { stream: true })
			let newline = buffer.indexOf('\n')
			while (newline >= 0) {
				const line = buffer.slice(0, newline).trim()
				buffer = buffer.slice(newline + 1)
				if (line) onFrame(JSON.parse(line) as T)
				newline = buffer.indexOf('\n')
			}
		}
	}
}

export type StateResponse = {
  config: string
  diskRevision: string
  activeRevision: string
  dirty: boolean
  running: boolean
}
export type SaveResponse = StateResponse & { saved?: boolean; applied?: boolean }
export type NetworkInterface = {
  logicalName: string
  l3Device: string
  addresses: Array<{ family: string; address: string; prefix: number }>
  defaultRoute?: { family: string; metric: number } | null
  kind: string
  parent?: string
  present: boolean
  up: boolean
  selectedBy: string
  safe: boolean
  reasonCodes: string[]
}
export type NetworkDiscovery = { ok: boolean; interfaces: NetworkInterface[]; recommended?: { lan?: string; wan?: string }; ambiguous?: boolean; error?: string }
export type GeoStatus = {
  ok?: boolean
  diskStatus?: string
  configuredPath?: string
  packages?: { geosite?: string; geoip?: string }
}
export type QuickState = {
  ok: boolean
  marker: boolean
  advancedOwned: boolean
  reasons: string[]
  revision: string
  running: boolean
  discovery: NetworkDiscovery
  subscriptions: SubscriptionStatus[]
  geo: GeoStatus
  presets: Array<{ id: string; requiresGeo: boolean }>
}
export type QuickInput = {
  preset: string
  lanDevice: string
  wanDevice: string
  subscriptionNames: string[]
  expectedRevision: string
  replaceAdvanced?: boolean
}
export type QuickPreview = {
  ok: boolean
  previewNonce: string
  expiresAt: number
  candidateSha256: string
  sourceSha256: string
  spanDigest: string
  preservedDigest: string
  compilerVersion: string
  projection: { preset: string; lanDevice: string; wanDevice: string; subscriptionNames: string[]; dns: string }
  diff: string
  additions: number
  removals: number
  blockedReasons: string[]
}
export type QuickApply = { ok: boolean; transaction?: Record<string, unknown>; result?: SaveResponse; error?: { code?: string; message?: string } }
export type SubscriptionStatus = {
  name: string
  enabled: boolean
  updateInterval: number
  nodeCount: number
  updatedAt?: string | null
  state: 'idle' | 'ready' | 'error'
  error?: string | null
}
export type SubscriptionDocument = { subscriptions: SubscriptionStatus[] }

export type ParsedNode = {
  raw: string
  name: string
  protocol: string
  host: string
  port: number
  username?: string
  password?: string
  tls: boolean
  sni?: string
  network?: string
  insecure?: boolean
  query?: Record<string, string>
  runtime?: boolean
  runtimeType?: string
  latency?: number
}

export type ConfigModel = {
  global: Record<string, string>
  nodes: ParsedNode[]
  groups: Array<{
    name: string
    policy: string
    final: string
    default?: string
    filter?: string
    raw: string
  }>
  subscriptions: Array<{ name: string; url: string; updateInterval?: number; enabled?: boolean }>
  routing: { rules: string[]; fallback: string }
  dns: {
    raw: string
    upstreams: DnsUpstream[]
    requestRules: string[]
    requestFallback: string
    responseRules: string[]
    responseFallback: string
  }
  experimental: { raw: string }
  rawConfig: string
}

export type DnsUpstream = {
  name: string
  value: string
  protocol: string
  host: string
  port: number
  path?: string
  sni?: string
  outbound?: string
  query?: Record<string, string>
}

export type ModelResponse = { ok: boolean; model: ConfigModel }
export type RuntimeNodesResponse = { ok: boolean; available: boolean; nodes: ParsedNode[]; error?: string; fetchedAt?: number }
export type PreviewResponse = {
  ok: boolean
  valid: boolean
  changed: boolean
  additions: number
  removals: number
  diff: string
  beforeRevision: string
  afterRevision: string
}
export type NodeTestOptions = { target?: string; url?: string; timeout?: number }
export type NodeTestResponse = { ok: boolean; passed: boolean; node: ParsedNode; summary: string; output: string }
