import type { ConnectivityCheck, ConnectivityResponse, DelayResponse, DiagnosticsResponse, DialMode, LogLevel, ModeInput, NetworkDiscovery, PreviewResponse, StateResponse, SubscriptionCacheResponse } from './types'

export type DefaultConfigResponse = {
  ok: boolean
  content: string
  revision: string
  templateRevision: string
}

const base = '/cgi-bin/luci/admin/services/honk/api'

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

function csrfToken(): string {
  const local = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''
  if (local || window.parent === window) return local
  try {
    return window.parent.document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''
  } catch {
    return ''
  }
}

async function request<T>(path: string, payload?: unknown): Promise<T> {
  const token = csrfToken()
  const endpoint = `${base}/${path}`
  const requestUrl = payload === undefined || !token ? endpoint : `${endpoint}?token=${encodeURIComponent(token)}`
  const response = await fetch(requestUrl, {
    method: payload === undefined ? 'GET' : 'POST',
    credentials: 'same-origin',
    cache: 'no-store',
    headers: payload === undefined ? { Accept: 'application/json' } : {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      ...(token ? { 'X-CSRF-Token': token } : {}),
    },
    body: payload === undefined ? undefined : JSON.stringify(payload),
  })
  const contentType = response.headers.get('content-type') || ''
  type ApiResponse = Record<string, unknown> & { ok?: boolean; error?: { code?: string; message?: string } }
  const fallback: ApiResponse = { ok: false, error: { code: `HTTP_${response.status}`, message: `HTTP ${response.status}` } }
  let data: ApiResponse = fallback
  if (contentType.includes('json')) {
    try {
      data = await response.json() as ApiResponse
    } catch {
      data = { ok: false, error: { code: 'INVALID_RESPONSE', message: `HTTP ${response.status}` } }
    }
  }
  if (!response.ok || data.ok === false) {
    throw new ApiRequestError(data.error?.message || `HTTP ${response.status}`, data.error?.code || 'REQUEST_FAILED', data)
  }
  return data as T
}

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
  applyInterfaces: (input: { lanDevice: string; wanDevice: string; dialMode: DialMode; logLevel: LogLevel; expectedRevision: string }) => request<{ ok: boolean; revision: string; running: boolean; interfaces: { lan: string; wan: string }; dialMode: DialMode; logLevel: LogLevel; config?: string }>('apply_interfaces', input),
  diagnostics: () => request<DiagnosticsResponse>('diagnostics'),
  geoSettings: (input: { geositeUrl: string; geoipUrl: string; allowCustom: boolean }) => request<{ ok: boolean; geositeUrl: string; geoipUrl: string; allowCustom: boolean }>('geo_settings', input),
  geoDownload: (kind: 'geosite' | 'geoip') => request<{ ok: boolean; kind: string; path: string; status?: string; needsRestart: boolean }>('geo_download', { kind }),
  logs: () => request<{ ok: boolean; lines: string }>('logs'),
  clearLogs: () => request<{ ok: boolean; cleared: boolean }>('clear_logs', {}),
}
