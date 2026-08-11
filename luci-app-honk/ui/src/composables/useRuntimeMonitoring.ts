import { computed, onBeforeUnmount, ref } from 'vue'
import { api } from '../api'
import { RuntimeClient } from '../runtime'
import type { ConnectionsDocument, MemoryFrame, ProxyDocument, RulesDocument, RuntimeConfig, RuntimeDashboardResponse, RuntimePrepareResponse, StatsDocument, TrafficFrame } from '../types'

const emptyConnections = (): ConnectionsDocument => ({ downloadTotal: 0, uploadTotal: 0, memory: 0, connections: [] })

export function useRuntimeMonitoring() {
  const bootstrap = ref<RuntimeDashboardResponse | null>(null)
  const config = ref<RuntimeConfig>({ mode: 'Rule' })
  const proxies = ref<ProxyDocument>({ proxies: {} })
  const connections = ref<ConnectionsDocument>(emptyConnections())
  const rules = ref<RulesDocument>({ rules: [] })
  const stats = ref<StatsDocument>({ outbounds: [] })
  const traffic = ref<TrafficFrame>({ up: 0, down: 0 })
  const trafficHistory = ref<TrafficFrame[]>([])
  const memory = ref(0)
  const loading = ref(false)
  const preparing = ref(false)
  const error = ref('')
  const closingIds = ref<string[]>([])
  const closingAll = ref(false)
  const ready = computed(() => bootstrap.value?.ready === true && bootstrap.value.running)
  let client: RuntimeClient | null = null
  let abort: AbortController | null = null
  let connectionsTimer = 0
  let snapshotTimer = 0
  let generation = 0
  let lastRevision = ''

  function teardown() {
    abort?.abort()
    abort = null
    window.clearInterval(connectionsTimer)
    window.clearInterval(snapshotTimer)
    connectionsTimer = 0
    snapshotTimer = 0
    client = null
  }

  function resetLiveData() {
    connections.value = emptyConnections()
    traffic.value = { up: 0, down: 0 }
    trafficHistory.value = []
    memory.value = 0
  }

  async function readConnections(activeClient = client) {
    if (!activeClient) return
    const next = await activeClient.connections()
    connections.value = next
    if (!memory.value) memory.value = next.memory || 0
  }

  async function readSnapshot(activeClient = client) {
    if (!activeClient) return
    const [nextConfig, nextProxies, nextRules, nextStats] = await Promise.all([
      activeClient.configs(), activeClient.proxies(), activeClient.rules(), activeClient.stats(),
    ])
    config.value = nextConfig
    proxies.value = nextProxies
    rules.value = nextRules
    stats.value = nextStats
  }

  function startStreams(activeClient: RuntimeClient, token: number) {
    abort = new AbortController()
    const signal = abort.signal
    void activeClient.stream<TrafficFrame>('/traffic', signal, frame => {
      if (token !== generation) return
      traffic.value = frame
      trafficHistory.value = [...trafficHistory.value.slice(-59), frame]
    }).catch(reason => { if (!signal.aborted && token === generation) error.value = (reason as Error).message })
    void activeClient.stream<MemoryFrame>('/memory', signal, frame => {
      if (token === generation) memory.value = frame.inuse
    }).catch(reason => { if (!signal.aborted && token === generation) error.value = (reason as Error).message })
  }

  async function activate(expectedRevision = lastRevision) {
    lastRevision = expectedRevision || lastRevision
    generation += 1
    const token = generation
    teardown()
    loading.value = true
    error.value = ''
    try {
      const next = await api.runtimeDashboard()
      if (token !== generation) return
      bootstrap.value = next
      if (!next.ready || !next.running) {
        resetLiveData()
        return
      }
      const activeClient = new RuntimeClient(next.controllerPort, next.secret)
      const [nextConnections, nextConfig, nextProxies, nextRules, nextStats] = await Promise.all([
        activeClient.connections(), activeClient.configs(), activeClient.proxies(), activeClient.rules(), activeClient.stats(),
      ])
      if (token !== generation) return
      client = activeClient
      connections.value = nextConnections
      config.value = nextConfig
      proxies.value = nextProxies
      rules.value = nextRules
      stats.value = nextStats
      memory.value = nextConnections.memory || 0
      startStreams(activeClient, token)
      connectionsTimer = window.setInterval(() => {
        void readConnections(activeClient).catch(reason => { if (token === generation) error.value = (reason as Error).message })
      }, 1500)
      snapshotTimer = window.setInterval(() => {
        void readSnapshot(activeClient).catch(reason => { if (token === generation) error.value = (reason as Error).message })
      }, 5000)
    } catch (reason) {
      if (token === generation) error.value = (reason as Error).message
    } finally {
      if (token === generation) loading.value = false
    }
  }

  function deactivate() {
    generation += 1
    teardown()
    loading.value = false
  }

  async function prepare(expectedRevision: string): Promise<RuntimePrepareResponse> {
    preparing.value = true
    error.value = ''
    try {
      const result = await api.prepareRuntime(expectedRevision)
      bootstrap.value = result.runtime
      await activate(result.revision)
      return result
    } catch (reason) {
      error.value = (reason as Error).message
      throw reason
    } finally {
      preparing.value = false
    }
  }

  async function closeConnection(id: string) {
    if (!client || closingIds.value.includes(id)) return
    closingIds.value = [...closingIds.value, id]
    try {
      await client.closeConnection(id)
      await readConnections()
    } finally {
      closingIds.value = closingIds.value.filter(value => value !== id)
    }
  }

  async function closeAllConnections() {
    if (!client || closingAll.value) return
    closingAll.value = true
    try {
      await client.closeAllConnections()
      await readConnections()
    } finally {
      closingAll.value = false
    }
  }

  onBeforeUnmount(deactivate)

  return {
    bootstrap, config, proxies, connections, rules, stats, traffic, trafficHistory, memory,
    loading, preparing, error, ready, closingIds, closingAll,
    activate, deactivate, prepare, retry: () => activate(lastRevision), closeConnection, closeAllConnections,
  }
}

export type RuntimeMonitoring = ReturnType<typeof useRuntimeMonitoring>
