import type { ConnectionsDocument, MemoryFrame, ProxyDocument, RulesDocument, RuntimeConfig, StatsDocument } from './types'

export class RuntimeClient {
  private readonly origin: string

  constructor(port: number, private readonly secret: string) {
    const rawHost = window.location.hostname
    const host = rawHost.includes(':') && !rawHost.startsWith('[') ? `[${rawHost}]` : rawHost
    this.origin = `${window.location.protocol}//${host}:${port}`
  }

  private async request<T>(path: string, init: RequestInit = {}): Promise<T> {
    const headers = new Headers(init.headers)
    headers.set('Accept', 'application/json')
    headers.set('Authorization', `Bearer ${this.secret}`)
    const response = await fetch(`${this.origin}${path}`, { ...init, headers, cache: 'no-store' })
    if (!response.ok) {
      const detail = await response.text().catch(() => '')
      throw new Error(detail || `Clash API HTTP ${response.status}`)
    }
    if (response.status === 204) return undefined as T
    return await response.json() as T
  }

  configs = () => this.request<RuntimeConfig>('/configs')
  proxies = () => this.request<ProxyDocument>('/proxies')
  connections = () => this.request<ConnectionsDocument>('/connections')
  rules = () => this.request<RulesDocument>('/rules')
  stats = () => this.request<StatsDocument>('/stats')
  closeConnection = (id: string) => this.request<void>(`/connections/${encodeURIComponent(id)}`, { method: 'DELETE' })
  closeAllConnections = () => this.request<void>('/connections', { method: 'DELETE' })

  async stream<T extends MemoryFrame | { up: number; down: number }>(path: string, signal: AbortSignal, onFrame: (frame: T) => void) {
    const response = await fetch(`${this.origin}${path}`, {
      cache: 'no-store',
      signal,
      headers: { Accept: 'application/json', Authorization: `Bearer ${this.secret}` },
    })
    if (!response.ok || !response.body) throw new Error(`Clash stream HTTP ${response.status}`)
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ''
    const consume = () => {
      let newline = buffer.indexOf('\n')
      while (newline >= 0) {
        const line = buffer.slice(0, newline).trim()
        buffer = buffer.slice(newline + 1)
        if (line) onFrame(JSON.parse(line) as T)
        newline = buffer.indexOf('\n')
      }
    }
    while (!signal.aborted) {
      const { done, value } = await reader.read()
      if (done) break
      buffer += decoder.decode(value, { stream: true })
      consume()
    }
    buffer += decoder.decode()
    if (buffer.trim()) onFrame(JSON.parse(buffer.trim()) as T)
  }
}
