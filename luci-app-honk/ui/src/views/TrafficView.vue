<script setup lang="ts">
import { computed } from 'vue'
import { Activity, ArrowDownToLine, ArrowUpFromLine, Cable, ChevronRight, Globe2, MemoryStick, Network, Router, Server, ShieldCheck, Waypoints } from '@lucide/vue'
import RuntimeGate from '../components/RuntimeGate.vue'
import TrafficChart from '../components/TrafficChart.vue'
import { t } from '../i18n'
import type { RuntimeMonitoring } from '../composables/useRuntimeMonitoring'
import type { RuntimeRule, StateResponse } from '../types'

const props = defineProps<{ state: StateResponse | null; runtime: RuntimeMonitoring }>()
const emit = defineEmits<{ changed: []; notice: [message: string]; error: [message: string] }>()
const runtime = props.runtime
const { bootstrap, config, proxies, connections, rules, stats, traffic, trafficHistory, memory, loading, preparing, error } = runtime

function formatBytes(value = 0) {
  if (!Number.isFinite(value) || value < 1024) return `${Math.max(0, Math.round(value || 0))} B`
  const units = ['KiB', 'MiB', 'GiB', 'TiB']
  let current = value
  let index = -1
  do { current /= 1024; index += 1 } while (current >= 1024 && index < units.length - 1)
  return `${current >= 10 ? current.toFixed(0) : current.toFixed(1)} ${units[index]}`
}

const primaryNode = computed(() => {
  const values = proxies.value.proxies
  const group = values.GLOBAL || values['honk-proxy'] || Object.values(values).find(item => Array.isArray(item.all) && item.now)
  const name = group?.now || ''
  const node = values[name]
  const history = node?.history || []
  const delay = history.length ? history[history.length - 1].delay : 0
  const outbound = stats.value.outbounds.find(item => item.name === name)
  return {
    name,
    type: node?.type || '',
    delay,
    connections: connections.value.connections.filter(item => item.chains.includes(name)).length,
    traffic: (outbound?.download || 0) + (outbound?.upload || 0),
  }
})
const totalTraffic = computed(() => connections.value.uploadTotal + connections.value.downloadTotal)
const activeOutbounds = computed(() => [...stats.value.outbounds]
  .sort((left, right) => (right.download + right.upload) - (left.download + left.upload))
  .slice(0, 5))
const nodeCount = computed(() => Math.max(
  bootstrap.value?.configuredNodeCount || 0,
  (props.state?.catalog.nodes.length || 0) + (props.state?.catalog.subscriptionNodes.length || 0),
))
const modeLabel = computed(() => {
  const mode = props.state?.mode
  if (mode === 'china-direct') return t('chinaDirect')
  if (mode === 'gfwlist') return t('gfw')
  if (mode === 'china-proxy') return t('chinaProxy')
  if (mode === 'global') return t('global')
  return config.value.mode || t('routeDefault')
})
const routeTarget = computed(() => primaryNode.value.name || t('direct'))
const ruleHint = computed(() => formatRule(rules.value.rules.find(item => item.proxy) || rules.value.rules[0]))

function formatRule(rule?: RuntimeRule) {
  if (!rule) return t('routeDefault')
  return [rule.type, rule.payload, rule.proxy].filter(Boolean).join(' · ') || t('routeDefault')
}

async function prepareRuntime() {
  if (!props.state?.revision) return
  try {
    await runtime.prepare(props.state.revision)
    emit('changed')
    emit('notice', t('runtimeMonitoringEnabled'))
  } catch (reason) {
    emit('error', (reason as Error).message)
  }
}
</script>

<template>
  <div class="page traffic-page">
    <header class="page-heading"><div><span class="eyebrow">{{ t('trafficLive') }}</span><h1>{{ t('trafficOverview') }}</h1></div></header>
    <RuntimeGate :bootstrap="bootstrap" :loading="loading" :preparing="preparing" :error="error" @prepare="prepareRuntime" @retry="runtime.retry" />

    <template v-if="bootstrap?.ready && bootstrap.running">
      <section class="active-node-card" :aria-label="t('currentPrimaryNode')">
        <div class="active-node-icon"><Server :size="20" /></div>
        <div class="active-node-copy"><span>{{ t('currentPrimaryNode') }}</span><strong>{{ primaryNode.name || t('noPrimaryNode') }}</strong><small>{{ primaryNode.type || t('routeDefault') }}</small></div>
        <dl><div><dt>{{ t('latencyTarget') }}</dt><dd>{{ primaryNode.delay ? primaryNode.delay + ' ms' : t('notMeasured') }}</dd></div><div><dt>{{ t('nodeConnections') }}</dt><dd>{{ primaryNode.connections }}</dd></div><div><dt>{{ t('nodeTraffic') }}</dt><dd>{{ formatBytes(primaryNode.traffic) }}</dd></div></dl>
      </section>

      <section class="runtime-metrics" :aria-label="t('realtimeStats')">
        <article><ArrowDownToLine :size="18" /><span>{{ t('downloadRate') }}</span><strong>{{ formatBytes(traffic.down) }}/s</strong></article>
        <article><ArrowUpFromLine :size="18" /><span>{{ t('uploadRate') }}</span><strong>{{ formatBytes(traffic.up) }}/s</strong></article>
        <article><Cable :size="18" /><span>{{ t('activeConnections') }}</span><strong>{{ connections.connections.length }}</strong></article>
        <article><MemoryStick :size="18" /><span>{{ t('memoryUsage') }}</span><strong>{{ formatBytes(memory || connections.memory) }}</strong></article>
      </section>

      <section class="traffic-overview-grid">
        <article class="runtime-panel traffic-chart-panel">
          <header><div><span>{{ t('last60Seconds') }}</span><h2>{{ t('realtimeTraffic') }}</h2></div><div class="chart-legend"><span class="download">{{ t('download') }}</span><span class="upload">{{ t('upload') }}</span></div></header>
          <TrafficChart :points="trafficHistory" :label="t('trafficChartLabel')" />
          <footer><span>{{ t('totalTraffic') }} <strong>{{ formatBytes(totalTraffic) }}</strong></span><span>{{ t('configuredNodes') }} <strong>{{ nodeCount }}</strong></span></footer>
        </article>
        <article class="runtime-panel outbound-panel">
          <header><div><span>{{ t('outboundActivity') }}</span><h2>{{ t('activeNow') }}</h2></div><Activity :size="19" /></header>
          <div v-if="activeOutbounds.length" class="runtime-data-list">
            <div v-for="outbound in activeOutbounds" :key="outbound.name" class="runtime-data-row"><div><strong>{{ outbound.name }}</strong><span>{{ outbound.activeConns }} {{ t('activeConnectionsUnit') }}</span></div><div><strong>{{ formatBytes(outbound.download + outbound.upload) }}</strong><span v-if="outbound.errors">{{ outbound.errors }} {{ t('outboundErrors') }}</span></div></div>
          </div>
          <div v-else class="runtime-inline-empty">{{ t('noOutboundTraffic') }}</div>
        </article>
      </section>

      <section class="runtime-topology-grid">
        <article class="runtime-panel topology-panel">
          <header><div><span>{{ t('dnsPath') }}</span><h2>{{ t('nameResolution') }}</h2></div><Globe2 :size="19" /></header>
          <div class="topology-flow"><div class="topology-node"><Router :size="17" /><strong>{{ t('lanDevices') }}</strong><span>{{ t('dnsRequests') }}</span></div><ChevronRight :size="18" /><div class="topology-node primary"><ShieldCheck :size="17" /><strong>{{ t('honkDns') }}</strong><span>{{ bootstrap.dns.bind }}</span></div><ChevronRight :size="18" /><div class="topology-destinations"><div><strong>{{ t('directDns') }}</strong><span>{{ bootstrap.dns.direct }}</span></div><div><strong>{{ t('proxyDns') }}</strong><span>{{ bootstrap.dns.proxy }}</span></div></div></div>
        </article>
        <article class="runtime-panel topology-panel">
          <header><div><span>{{ t('routingPath') }}</span><h2>{{ modeLabel }}</h2></div><Network :size="19" /></header>
          <div class="topology-flow"><div class="topology-node"><Waypoints :size="17" /><strong>{{ t('deviceTraffic') }}</strong><span>{{ t('transparentTakeover') }}</span></div><ChevronRight :size="18" /><div class="topology-node primary"><Network :size="17" /><strong>{{ modeLabel }}</strong><span>{{ rules.rules.length }} {{ t('ruleCount') }}</span></div><ChevronRight :size="18" /><div class="topology-node"><Server :size="17" /><strong>{{ routeTarget }}</strong><span>{{ t('outbound') }}</span></div></div>
          <p>{{ t('currentRule') }}: {{ ruleHint }}</p>
        </article>
      </section>
    </template>
  </div>
</template>
