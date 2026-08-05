import { computed, onBeforeUnmount, ref } from 'vue'
import {
  api,
  ClashClient,
  type ClashConfig,
  type ConnectionsDocument,
  type LogFrame,
  type MemoryFrame,
  type ProxyDocument,
  type RulesDocument,
  type RuntimeBootstrap,
  type StatsDocument,
  type SubscriptionDocument,
  type TrafficFrame,
} from '../api'

const emptyConnections = (): ConnectionsDocument => ({
  downloadTotal: 0,
  uploadTotal: 0,
  memory: 0,
  connections: [],
})

export function useRuntime() {
  const bootstrap = ref<RuntimeBootstrap | null>(null)
  const config = ref<ClashConfig>({ mode: 'Rule' })
  const proxies = ref<ProxyDocument>({ proxies: {} })
  const connections = ref<ConnectionsDocument>(emptyConnections())
  const rules = ref<RulesDocument>({ rules: [] })
  const stats = ref<StatsDocument>({ outbounds: [] })
  const subscriptions = ref<SubscriptionDocument>({ subscriptions: [] })
  const traffic = ref<TrafficFrame>({ up: 0, down: 0 })
  const trafficHistory = ref<TrafficFrame[]>([])
  const memory = ref(0)
  const logs = ref<LogFrame[]>([])
  const loading = ref(true)
  const busy = ref(false)
  const error = ref('')
  let client: ClashClient | null = null
  let abort: AbortController | null = null
  let connectionsTimer = 0
  let snapshotTimer = 0

  const running = computed(() => bootstrap.value?.running === true)
  const groups = computed(() => Object.values(proxies.value.proxies).filter(item => Array.isArray(item.all)))
  const nodes = computed(() => Object.values(proxies.value.proxies).filter(item =>
    !Array.isArray(item.all) && item.type.toLowerCase() !== 'direct'))

  function stopRuntime() {
    abort?.abort()
    abort = null
    window.clearInterval(connectionsTimer)
    window.clearInterval(snapshotTimer)
    connectionsTimer = 0
    snapshotTimer = 0
    client = null
  }

  type InitializeOptions = {
    expectedRunning?: boolean
    retries?: number
    retryDelay?: number
  }

  const wait = (milliseconds: number) => new Promise(resolve => window.setTimeout(resolve, milliseconds))

  function isTransientError(reason: unknown) {
    const message = reason instanceof Error ? reason.message : String(reason)
    return reason instanceof TypeError || /failed to fetch|networkerror|connection refused|http 502|http 503/i.test(message)
  }

  function resetStoppedState() {
    connections.value = emptyConnections()
    traffic.value = { up: 0, down: 0 }
    trafficHistory.value = []
    memory.value = 0
    logs.value = []
  }

  async function refreshConnections() {
    if (!client) return
    connections.value = await client.connections()
    if (!memory.value) memory.value = connections.value.memory || 0
  }

  async function refreshSnapshot() {
    if (!client) return
    const [nextConfig, nextProxies, nextRules, nextStats, nextSubscriptions] = await Promise.all([
      client.configs(),
      client.proxies(),
      client.rules(),
      client.stats(),
      client.subscriptions(),
    ])
    config.value = nextConfig
    proxies.value = nextProxies
    rules.value = nextRules
    stats.value = nextStats
    subscriptions.value = nextSubscriptions
  }

  function startStreams() {
    if (!client) return
    abort = new AbortController()
    const signal = abort.signal
    void client.stream<TrafficFrame>('/traffic', signal, frame => {
      traffic.value = frame
      trafficHistory.value = [...trafficHistory.value.slice(-59), frame]
    }).catch(reason => {
      if (!signal.aborted) error.value = (reason as Error).message
    })
    void client.stream<MemoryFrame>('/memory', signal, frame => {
      memory.value = frame.inuse
    }).catch(reason => {
      if (!signal.aborted) error.value = (reason as Error).message
    })
    void client.stream<LogFrame>('/logs?level=info', signal, frame => {
      logs.value = [...logs.value.slice(-499), frame]
    }).catch(reason => {
      if (!signal.aborted) error.value = (reason as Error).message
    })
  }

  async function initialize(options: InitializeOptions = {}) {
    const expectedRunning = options.expectedRunning
    const retries = options.retries ?? 3
    const retryDelay = options.retryDelay ?? 400
    loading.value = true
    error.value = ''
    try {
      for (let attempt = 0; attempt <= retries; attempt += 1) {
        stopRuntime()
        try {
        let next = await api.dashboard()
        if (next.needsMigration) next = await api.dashboardPrepare()
        bootstrap.value = next
        if (expectedRunning !== undefined && next.running !== expectedRunning) {
          if (attempt < retries) {
            await wait(retryDelay)
            continue
          }
          throw new Error(expectedRunning ? '启动状态确认超时，请稍后刷新' : '停止状态确认超时，请稍后刷新')
        }
        if (!next.running) {
          resetStoppedState()
          return
        }
        client = new ClashClient(next.controllerPort, next.secret)
        try {
          await Promise.all([refreshConnections(), refreshSnapshot()])
        } catch (reason) {
          stopRuntime()
          if (attempt < retries && isTransientError(reason)) {
            await wait(retryDelay)
            continue
          }
          throw reason
        }
        startStreams()
        connectionsTimer = window.setInterval(() => {
          void refreshConnections().catch(reason => { error.value = (reason as Error).message })
        }, 1500)
        snapshotTimer = window.setInterval(() => {
          void refreshSnapshot().catch(reason => { error.value = (reason as Error).message })
        }, 5000)
        return
        } catch (reason) {
          if (attempt < retries && isTransientError(reason)) {
            await wait(retryDelay)
            continue
          }
          error.value = reason instanceof Error ? reason.message : String(reason)
          return
        }
      }
    } finally {
      loading.value = false
    }
  }

  async function service(action: 'start' | 'stop' | 'restart' | 'reload') {
    busy.value = true
    error.value = ''
    if (action !== 'start') stopRuntime()
    try {
      await api.service(action)
      await initialize({
        expectedRunning: action === 'stop' ? false : true,
        retries: action === 'stop' ? 20 : 30,
        retryDelay: 400,
      })
    } catch (reason) {
      error.value = (reason as Error).message
    } finally {
      busy.value = false
    }
  }

  async function setMode(mode: string) {
    if (!client) return
    busy.value = true
    try {
      await client.setMode(mode)
      config.value = { ...config.value, mode }
    } finally {
      busy.value = false
    }
  }

  async function selectProxy(group: string, name: string) {
    if (!client) return
    busy.value = true
    try {
      await client.selectProxy(group, name)
      await refreshSnapshot()
    } finally {
      busy.value = false
    }
  }

  async function testProxy(name: string, url: string) {
    if (!client) return 0
    const result = await client.testProxy(name, url)
    await refreshSnapshot()
    return result.delay
  }

  async function testGroup(name: string, url: string) {
    if (!client) return {}
    const result = await client.testGroup(name, url)
    await refreshSnapshot()
    return result
  }

  async function refreshSubscription(name: string) {
    if (!client) return
    busy.value = true
    try {
      await client.refreshSubscription(name)
      await new Promise(resolve => window.setTimeout(resolve, 700))
      await refreshSnapshot()
    } finally {
      busy.value = false
    }
  }

  async function closeConnection(id: string) {
    if (!client) return
    await client.closeConnection(id)
    await refreshConnections()
  }

  async function closeAllConnections() {
    if (!client) return
    await client.closeAllConnections()
    await refreshConnections()
  }

  onBeforeUnmount(stopRuntime)

  return {
    bootstrap,
    config,
    proxies,
    connections,
    rules,
    stats,
    subscriptions,
    traffic,
    trafficHistory,
    memory,
    logs,
    loading,
    busy,
    error,
    running,
    groups,
    nodes,
    initialize,
    refreshConnections,
    refreshSnapshot,
    service,
    setMode,
    selectProxy,
    testProxy,
    testGroup,
    refreshSubscription,
    closeConnection,
    closeAllConnections,
  }
}
