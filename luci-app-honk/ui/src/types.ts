export type ModeName = 'china-direct' | 'gfwlist' | 'china-proxy' | 'global'
export type SourceKind = 'node' | 'subscription'

export type SourceItem = {
  name: string
  kind: SourceKind
  protocol: string
  enabled?: boolean
  updateInterval?: number
  cacheSource?: 'cache' | 'stale' | 'missing'
  cachedAt?: string
  cachedNodeCount?: number
  cachedError?: string
  cachedErrorAt?: string
}

export type RuntimeNodeItem = {
  name: string
  subscription: string
  protocol: string
  source?: 'runtime' | 'cache' | 'stale'
}

export type SubscriptionCacheRecord = {
  name: string
  nodeCount: number
  nodes: RuntimeNodeItem[]
  sha256?: string
  updatedAt?: string
  updatedEpoch?: number
  lastError?: string
  lastErrorAt?: string
  stale?: boolean
  source?: 'cache' | 'stale' | 'missing'
}

export type SubscriptionCacheResponse = {
  ok: boolean
  name: string
  cache: SubscriptionCacheRecord
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
  catalog: { nodes: SourceItem[]; subscriptions: SourceItem[]; subscriptionNodes: RuntimeNodeItem[]; runtimeAvailable?: boolean; runtimeConfigured?: boolean; cacheAvailable?: boolean }
  selected: { nodes: string[]; subscriptions: string[] }
  deviceRules: DeviceRule[]
  last: LastState
  recentError?: string
  rollback: boolean
  backupAvailable: boolean
  clashApi: { enabled: boolean; controller: string; port?: number; secretConfigured: boolean }
  localDns: { enabled: boolean; servers: string; active: boolean; owned: boolean; path: string; endpoint?: string; dnsmasq?: Record<string, unknown> }
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
  geo: { valid: boolean; detail: GeoDiagnostics }
  files: {
    valid: boolean
    core: RuntimeFileDiagnostic
    tool: RuntimeFileDiagnostic
    init: RuntimeFileDiagnostic
    config: RuntimeFileDiagnostic
    defaultConfig: RuntimeFileDiagnostic
    backup: RuntimeFileDiagnostic
    launcher: RuntimeFileDiagnostic
    interfaceDiscovery: RuntimeFileDiagnostic
    quickWorker: RuntimeFileDiagnostic
    geosite: RuntimeFileDiagnostic
    geoip: RuntimeFileDiagnostic
  }
  last: LastState
}

export type RuntimeFileDiagnostic = {
  path: string
  exists: boolean
  regular: boolean
  executable: boolean
  size: number
  ok: boolean
  reason?: string
  version?: string
}

export type GeoAssetDiagnostic = {
  kind: 'geosite' | 'geoip'
  path: string
  package: string
  status: string
  size: number
  ok: boolean
}

export type GeoDiagnostics = {
  ok: boolean
  directory: string
  provider: string
  assets: { geosite: GeoAssetDiagnostic; geoip: GeoAssetDiagnostic }
}

export type DialMode = 'ip' | 'domain' | 'domain+' | 'domain++'
export type LogLevel = 'trace' | 'debug' | 'info' | 'warn' | 'error'

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

export type RuntimeDnsSummary = {
  bind: string
  direct: string
  proxy: string
}

export type RuntimeDashboardResponse = {
  ok: boolean
  ready: boolean
  needsPreparation: boolean
  running: boolean
  controllerPort: number
  secret: string
  reasons: string[]
  configuredNodeCount: number
  dns: RuntimeDnsSummary
}

export type RuntimePrepareResponse = {
  ok: boolean
  changed: boolean
  revision: string
  running: boolean
  runtime: RuntimeDashboardResponse
}

export type DelayHistory = { time: string; delay: number }
export type RuntimeProxy = {
  name: string
  type: string
  all?: string[]
  now?: string
  history?: DelayHistory[]
  udp?: boolean
}
export type ProxyDocument = { proxies: Record<string, RuntimeProxy> }
export type RuntimeConfig = { mode: string; 'mode-list'?: string[] }
export type ConnectionInfo = {
  id: string
  metadata: {
    network: string
    sourceIP: string
    destinationIP: string
    sourcePort: string
    destinationPort: string
    host: string
    process?: string
    processPath?: string
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
export type RuntimeRule = { type?: string; payload?: string; proxy?: string; size?: number }
export type RulesDocument = { rules: RuntimeRule[] }
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
