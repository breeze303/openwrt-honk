import type { ConnectivityCheck, ConnectivityResponse, DelayResponse, DiagnosticsResponse, DialMode, LogLevel, ModeInput, NetworkDiscovery, PreviewResponse, RuntimeDashboardResponse, RuntimePrepareResponse, StateResponse, SubscriptionCacheResponse } from './types'

export type DefaultConfigResponse = {
  ok: boolean
  content: string
  revision: string
  templateRevision: string
}

const PROTOCOL_VERSION = 1
const REQUEST_TIMEOUT = 30000

export class ApiRequestError extends Error {
  constructor(message: string, readonly code: string, readonly data: Record<string, unknown>) {
    super(message)
  }
}

function listValue<T>(value: unknown): T[] {
  if (Array.isArray(value)) return value as T[]
  if (!value || typeof value !== 'object') return []
  return Object.entries(value as Record<string, T>)
    .filter(([key]) => /^\d+$/.test(key))
    .sort(([left], [right]) => Number(left) - Number(right))
    .map(([, item]) => item)
}

function normalizeState(value: StateResponse): StateResponse {
  const raw = value as StateResponse & {
    catalog?: {
      nodes?: unknown
      subscriptions?: unknown
      subscriptionNodes?: unknown
      runtimeAvailable?: boolean
      runtimeConfigured?: boolean
      cacheAvailable?: boolean
    }
    selected?: { nodes?: unknown; subscriptions?: unknown }
    deviceRules?: unknown
  }
  const catalog = raw.catalog || {}
  const selected = raw.selected || {}
  return {
    ...raw,
    catalog: {
      nodes: listValue(catalog.nodes),
      subscriptions: listValue(catalog.subscriptions),
      subscriptionNodes: listValue(catalog.subscriptionNodes),
      runtimeAvailable: catalog.runtimeAvailable,
      runtimeConfigured: catalog.runtimeConfigured,
      cacheAvailable: catalog.cacheAvailable,
    },
    selected: {
      nodes: listValue(selected.nodes),
      subscriptions: listValue(selected.subscriptions),
    },
    deviceRules: listValue(raw.deviceRules),
  }
}

type ApiResponse = Record<string, unknown> & { ok?: boolean; error?: { code?: string; message?: string } }
type BridgeMessage = {
  type?: string
  version?: number
  requestId?: string
  result?: ApiResponse
  error?: { code?: string; message?: string }
}

class BridgeClient {
  private readonly origin = window.location.origin
  private readonly pending = new Map<string, { resolve: (value: ApiResponse) => void; reject: (reason: Error) => void; timer: number }>()
  private readyPromise: Promise<void>
  private sequence = 0

  constructor() {
    this.readyPromise = new Promise((resolve, reject) => {
      if (window.parent === window) {
        reject(new ApiRequestError('Honk must be opened from LuCI.', 'BRIDGE_UNAVAILABLE', {}))
        return
      }
      const timeout = window.setTimeout(() => {
        window.removeEventListener('message', onReady)
        reject(new ApiRequestError('LuCI bridge did not become ready.', 'BRIDGE_TIMEOUT', {}))
      }, 10000)
      const onReady = (event: MessageEvent<BridgeMessage>) => {
        if (event.origin !== this.origin || event.source !== window.parent) return
        if (event.data?.type !== 'honk-bridge-ready' || event.data.version !== PROTOCOL_VERSION) return
        window.clearTimeout(timeout)
        window.removeEventListener('message', onReady)
        resolve()
      }
      window.addEventListener('message', onReady)
      window.parent.postMessage({ type: 'honk-bridge-handshake', version: PROTOCOL_VERSION }, this.origin)
    })
    window.addEventListener('message', event => this.receive(event as MessageEvent<BridgeMessage>))
  }

  private receive(event: MessageEvent<BridgeMessage>) {
    if (event.origin !== this.origin || event.source !== window.parent) return
    const data = event.data
    if (data?.type !== 'honk-bridge-response' || typeof data.requestId !== 'string') return
    const pending = this.pending.get(data.requestId)
    if (!pending) return
    this.pending.delete(data.requestId)
    window.clearTimeout(pending.timer)
    if (data.error) {
      pending.reject(new ApiRequestError(data.error.message || 'Bridge request failed.', data.error.code || 'REQUEST_FAILED', {}))
      return
    }
    if (!data.result || typeof data.result !== 'object') {
      pending.reject(new ApiRequestError('Invalid bridge response.', 'INVALID_RESPONSE', {}))
      return
    }
    pending.resolve(data.result)
  }

  private requestId() {
    this.sequence += 1
    const bytes = new Uint32Array(1)
    window.crypto.getRandomValues(bytes)
    return `honk_${Date.now().toString(36)}_${this.sequence.toString(36)}_${bytes[0].toString(36)}`
  }

  async request<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    await this.readyPromise
    const requestId = this.requestId()
    const response = await new Promise<ApiResponse>((resolve, reject) => {
      const timer = window.setTimeout(() => {
        this.pending.delete(requestId)
        reject(new ApiRequestError('Bridge request timed out.', 'REQUEST_TIMEOUT', {}))
      }, REQUEST_TIMEOUT)
      this.pending.set(requestId, { resolve, reject, timer })
      window.parent.postMessage({ type: 'honk-bridge-request', version: PROTOCOL_VERSION, requestId, method, params }, this.origin)
    })
    if (response.ok === false) {
      throw new ApiRequestError(response.error?.message || 'Request failed.', response.error?.code || 'REQUEST_FAILED', response)
    }
    return response as T
  }
}

const bridge = new BridgeClient()
const request = <T>(method: string, params: Record<string, unknown> = {}) => bridge.request<T>(method, params)

export const api = {
  state: () => request<StateResponse>('state').then(normalizeState),
  preview: (input: ModeInput) => request<PreviewResponse>('preview', input),
  apply: (input: ModeInput) => request<{ ok: boolean; revision: string }>('apply', input),
  service: (action: 'start' | 'stop' | 'restart') => request<{ ok: boolean; state: StateResponse }>('service', { action })
    .then(result => ({ ...result, state: normalizeState(result.state) })),
  mutateSource: (input: Record<string, unknown>) => request<{ ok: boolean }>('sources', input),
  refreshSubscription: (name: string) => request<{ ok: boolean; accepted: boolean }>('refresh_subscription', { name }),
  subscriptionCache: (name: string) => request<SubscriptionCacheResponse>('subscription_cache', { name }),
  deleteSubscriptionCache: (name: string) => request<{ ok: boolean; name: string; removed: boolean }>('delete_subscription_cache', { name }),
  delay: (name: string) => request<DelayResponse>('delay', { name }),
  connectivity: (id: ConnectivityCheck['id']) => request<ConnectivityResponse>('connectivity', { id }),
  advanced: () => request<StateResponse>('advanced').then(normalizeState),
  defaultConfig: () => request<DefaultConfigResponse>('default_config'),
  resetConfig: (expectedRevision: string) => request<{ ok: boolean; revision: string; running: boolean; rollback: boolean }>('reset_config', { expectedRevision }),
  validateAdvanced: (config: string) => request<{ ok: boolean; revision: string }>('validate_advanced', { config }),
  applyAdvanced: (config: string, expectedRevision: string) => request<{ ok: boolean; revision: string }>('apply_advanced', { config, expectedRevision }),
  toggleClashApi: (enabled: boolean, expectedRevision: string) => request<{ ok: boolean; enabled: boolean; changed: boolean; revision: string }>('toggle_clash_api', { enabled, expectedRevision }),
  networkInterfaces: () => request<NetworkDiscovery>('network_interfaces'),
  applyInterfaces: (input: { lanDevice: string; wanDevice: string; dialMode: DialMode; logLevel: LogLevel; dnsmasqForwarding: boolean; expectedRevision: string }) => request<{ ok: boolean; revision: string; running: boolean; interfaces: { lan: string; wan: string }; dialMode: DialMode; logLevel: LogLevel; localDns: StateResponse['localDns']; config?: string }>('apply_interfaces', input),
  diagnostics: () => request<DiagnosticsResponse>('diagnostics'),
  logs: () => request<{ ok: boolean; lines: string }>('logs'),
  clearLogs: () => request<{ ok: boolean; cleared: boolean }>('clear_logs', {}),
  runtimeDashboard: () => request<RuntimeDashboardResponse>('runtime_dashboard'),
  prepareRuntime: (expectedRevision: string) => request<RuntimePrepareResponse>('runtime_prepare', { expectedRevision }),
}
