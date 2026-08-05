export type ModeName = 'china-direct' | 'gfwlist' | 'china-proxy' | 'global'
export type SourceKind = 'node' | 'subscription'

export type SourceItem = {
  name: string
  kind: SourceKind
  protocol: string
  enabled?: boolean
  updateInterval?: number
}

export type RuntimeNodeItem = {
  name: string
  subscription: string
  protocol: string
}

export type NodeDelay = {
  status: 'idle' | 'testing' | 'ok' | 'error'
  delay?: number
  error?: string
}

export type DelayResponse = {
  ok: boolean
  name: string
  delay: number
  target: string
}

export type ConnectivityCheck = {
  id: 'aliyun' | 'google' | 'github' | 'youtube'
  url: string
  route: 'direct' | 'honk-proxy'
  ok: boolean
  status: number
  latency?: number
  error?: string
}

export type ConnectivityResponse = {
  ok: boolean
  passed: boolean
  check: ConnectivityCheck
  testedAt: string
}

export type DeviceRule = {
  kind: 'ip' | 'mac'
  value: string
  outbound: 'direct' | 'proxy'
}

export type LastState = {
  stage: string
  updatedAt?: string
  activeRevision?: string
  recentError?: string
  rollback?: boolean
}

export type StateResponse = {
  ok: boolean
  running: boolean
  revision: string
  activeRevision: string
  dirty: boolean
  mode: ModeName | null
  managed: boolean
  requiresTakeover: boolean
  catalog: { nodes: SourceItem[]; subscriptions: SourceItem[]; subscriptionNodes: RuntimeNodeItem[]; runtimeAvailable?: boolean; runtimeConfigured?: boolean }
  selected: { nodes: string[]; subscriptions: string[] }
  deviceRules: DeviceRule[]
  last: LastState
  recentError?: string
  rollback: boolean
  backupAvailable: boolean
  clashApi: { enabled: boolean; controller: string; port?: number; secretConfigured: boolean }
  config?: string
}

export type ModeInput = {
  mode: ModeName
  nodeNames: string[]
  subscriptionNames: string[]
  deviceRules: DeviceRule[]
  expectedRevision: string
  takeover?: boolean
}

export type PreviewResponse = {
  ok: boolean
  mode: ModeName
  previousMode: ModeName | null
  requiresTakeover: boolean
  expectedRevision: string
  candidateRevision: string
  routing: string[]
  dns: string[]
  changes: { additions: number; removals: number }
}

export type DiagnosticsResponse = {
  ok: boolean
  service: { running: boolean; init: boolean }
  config: { valid: boolean; detail: string; revision: string; bytes: number }
  geo: { valid: boolean; detail: Record<string, unknown> }
  files: { config: boolean; backup: boolean; tool: boolean }
  last: LastState
}

export type DialMode = 'ip' | 'domain' | 'domain+' | 'domain++'

export type NetworkAddress = {
  family: 'ipv4' | 'ipv6'
  address: string
  prefix: number
}

export type NetworkRoute = {
  family: 'ipv4' | 'ipv6'
  metric: number
  gateway?: string
}

export type NetworkInterface = {
  logicalName: string
  l3Device: string
  device?: string
  parent?: string
  kind: string
  addresses: NetworkAddress[]
  defaultRoute?: NetworkRoute | null
  defaultRoutes: NetworkRoute[]
  present: boolean
  up: boolean
  safe: boolean
  selectedBy?: string
  reasonCodes: string[]
}

export type NetworkDiscovery = {
  ok: boolean
  interfaces: NetworkInterface[]
  candidates: NetworkInterface[]
  recommended: { lan?: string; wan?: string }
  ambiguous: boolean
  reasonCodes?: string[]
  error?: string
  current?: { lan: string; wan: string; dialMode: DialMode }
  revision?: string
}
