<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import {
  Activity,
  ArrowDownToLine,
  ArrowUpFromLine,
  Cable,
  ChevronRight,
  Globe2,
  MemoryStick,
  Network,
  Router,
  Server,
  ShieldCheck,
  TriangleAlert,
  Waypoints,
} from '@lucide/vue'
import { api, type ClashRule, type ConfigModel, type ConnectionsDocument, type OutboundStat, type ProxyInfo, type RulesDocument, type TrafficFrame } from '../api'
import TrafficSparkline from '../components/TrafficSparkline.vue'

const props = defineProps<{
  running: boolean
  mode: string
  traffic: TrafficFrame
  history: TrafficFrame[]
  memory: number
  connections: ConnectionsDocument
  outbounds: OutboundStat[]
  nodeCount: number
  proxies: Record<string, ProxyInfo>
  rules: RulesDocument
}>()
const emit = defineEmits<{ mode: [value: string] }>()

const model = ref<ConfigModel | null>(null)

const formatBytes = (value = 0) => {
  if (value < 1024) return Math.round(value) + ' B'
  const units = ['KiB', 'MiB', 'GiB', 'TiB']
  let current = value
  let index = -1
  do { current /= 1024; index += 1 } while (current >= 1024 && index < units.length - 1)
  return (current >= 10 ? current.toFixed(0) : current.toFixed(1)) + ' ' + units[index]
}

const totalTraffic = computed(() => props.connections.uploadTotal + props.connections.downloadTotal)
const activeOutbounds = computed(() => [...props.outbounds]
  .sort((a, b) => (b.download + b.upload) - (a.download + a.upload))
  .slice(0, 5))
const primaryNode = computed(() => {
  const name = props.proxies.GLOBAL?.now || ''
  const proxy = props.proxies[name]
  const history = proxy?.history || []
  const delay = history.length ? history[history.length - 1].delay : 0
  const outbound = props.outbounds.find(item => item.name === name)
  const connections = props.connections.connections.filter(item => item.chains.includes(name)).length
  return {
    name,
    type: proxy?.type || '未选择',
    delay,
    connections,
    traffic: (outbound?.download || 0) + (outbound?.upload || 0),
  }
})
const primaryStatus = computed(() => {
  if (!props.running) return '服务停止'
  if (!primaryNode.value.name || primaryNode.value.name === 'direct') return '等待选择'
  if (props.mode.toLowerCase() === 'direct') return '待命'
  return '正在使用'
})
const modeLabel = computed(() => {
  if (props.mode.toLowerCase() === 'global') return '全局'
  if (props.mode.toLowerCase() === 'direct') return '直连'
  return '规则'
})
const routeTarget = computed(() => {
  if (props.mode.toLowerCase() === 'direct') return { title: '直连出口', detail: '全部流量直连' }
  if (!primaryNode.value.name || primaryNode.value.name === 'direct') return { title: '等待主节点', detail: '选择节点后即可代理' }
  return {
    title: primaryNode.value.name,
    detail: props.mode.toLowerCase() === 'global' ? '全局代理出口' : '命中代理规则时使用',
  }
})
const dnsTarget = computed(() => {
  const upstream = model.value?.dns.upstreams?.[0]
  if (!upstream) return { title: '系统 DNS', detail: '沿用系统上游' }
  return { title: upstream.name || 'DNS 上游', detail: upstream.value || '已配置上游' }
})
const ruleHint = computed(() => {
  const rule = props.rules.rules.find(item => item.proxy) || props.rules.rules[0]
  return formatRule(rule)
})

function formatRule(rule?: ClashRule) {
  if (!rule) return '使用默认路由'
  return [rule.type, rule.payload].filter(Boolean).join(' · ') || rule.proxy || '使用默认路由'
}

onMounted(() => {
  void api.model()
    .then(result => { model.value = result.model })
    .catch(() => { model.value = null })
})
</script>

<template>
  <section class="view-stack overview-view">
    <header class="view-heading">
      <div>
        <p class="eyebrow">运行概览</p>
        <h1>网络状态</h1>
      </div>
      <div class="segmented" aria-label="代理模式">
        <button
          v-for="item in ['Rule', 'Global', 'Direct']"
          :key="item"
          :class="{ active: mode.toLowerCase() === item.toLowerCase() }"
          :disabled="!running"
          @click="emit('mode', item)"
        >{{ item === 'Rule' ? '规则' : item === 'Global' ? '全局' : '直连' }}</button>
      </div>
    </header>

    <div v-if="!running" class="empty-state compact">
      <TriangleAlert :size="20" />
      <div><strong>Honk 服务已停止</strong><span>启动服务后显示实时节点、连接和流量。</span></div>
    </div>

    <section class="active-node-card" :class="{ standby: mode.toLowerCase() === 'direct' }" aria-label="当前主节点">
      <div class="active-node-icon"><Server :size="21" /></div>
      <div class="active-node-copy">
        <p class="eyebrow">当前主节点</p>
        <strong>{{ primaryNode.name || '尚未选择节点' }}</strong>
        <span>{{ primaryNode.name ? primaryNode.type : '从节点页选择一个节点作为统一出口' }}</span>
      </div>
      <div class="active-node-stat">
        <span>{{ primaryStatus }}</span>
        <strong>{{ primaryNode.delay ? primaryNode.delay + ' ms' : '未测速' }}</strong>
      </div>
      <div class="active-node-stat">
        <span>节点连接</span>
        <strong>{{ primaryNode.connections }}</strong>
      </div>
      <div class="active-node-stat">
        <span>节点流量</span>
        <strong>{{ formatBytes(primaryNode.traffic) }}</strong>
      </div>
    </section>

    <section class="metric-grid" aria-label="实时统计">
      <article class="metric-card">
        <ArrowDownToLine :size="18" />
        <span>下载速度</span>
        <strong>{{ formatBytes(traffic.down) }}/s</strong>
      </article>
      <article class="metric-card accent-warm">
        <ArrowUpFromLine :size="18" />
        <span>上传速度</span>
        <strong>{{ formatBytes(traffic.up) }}/s</strong>
      </article>
      <article class="metric-card">
        <Cable :size="18" />
        <span>活动连接</span>
        <strong>{{ connections.connections.length }}</strong>
      </article>
      <article class="metric-card">
        <MemoryStick :size="18" />
        <span>内存占用</span>
        <strong>{{ formatBytes(memory || connections.memory) }}</strong>
      </article>
    </section>

    <section class="overview-grid">
      <article class="surface-panel traffic-chart-panel">
        <header class="panel-heading">
          <div><p class="eyebrow">最近 60 秒</p><h2>实时流量</h2></div>
          <div class="chart-legend"><span class="down">下载</span><span class="up">上传</span></div>
        </header>
        <TrafficSparkline :points="history" label="最近六十秒上传和下载趋势" />
        <footer class="chart-summary">
          <span>累计流量 <strong>{{ formatBytes(totalTraffic) }}</strong></span>
          <span>节点 <strong>{{ nodeCount }}</strong></span>
        </footer>
      </article>

      <article class="surface-panel outbound-panel">
        <header class="panel-heading">
          <div><p class="eyebrow">出口状态</p><h2>当前活动</h2></div>
          <Activity :size="19" />
        </header>
        <div v-if="activeOutbounds.length" class="data-list">
          <div v-for="outbound in activeOutbounds" :key="outbound.name" class="data-row">
            <div><strong>{{ outbound.name }}</strong><span>{{ outbound.activeConns }} 个活动连接</span></div>
            <div class="row-numbers"><strong>{{ formatBytes(outbound.download + outbound.upload) }}</strong><span v-if="outbound.errors">{{ outbound.errors }} 次错误</span></div>
          </div>
        </div>
        <div v-else class="inline-empty">暂无出口流量</div>
      </article>
    </section>

    <section class="topology-grid" aria-label="当前网络路径">
      <article class="surface-panel topology-panel">
        <header class="panel-heading">
          <div><p class="eyebrow">当前 DNS 路径</p><h2>名称解析</h2></div>
          <Globe2 :size="19" />
        </header>
        <div class="topology-flow">
          <div class="topology-node"><Router :size="17" /><strong>局域网设备</strong><span>DNS 请求</span></div>
          <ChevronRight class="topology-link" :size="18" aria-hidden="true" />
          <div class="topology-node primary"><ShieldCheck :size="17" /><strong>Honk DNS</strong><span>规则处理</span></div>
          <ChevronRight class="topology-link" :size="18" aria-hidden="true" />
          <div class="topology-node"><Globe2 :size="17" /><strong>{{ dnsTarget.title }}</strong><span>{{ dnsTarget.detail }}</span></div>
        </div>
        <p class="topology-caption">当前上游由已应用的 DNS 配置决定。</p>
      </article>

      <article class="surface-panel topology-panel">
        <header class="panel-heading">
          <div><p class="eyebrow">当前规则路径</p><h2>{{ modeLabel }}模式流向</h2></div>
          <Network :size="19" />
        </header>
        <div class="topology-flow">
          <div class="topology-node"><Waypoints :size="17" /><strong>设备流量</strong><span>透明接管</span></div>
          <ChevronRight class="topology-link" :size="18" aria-hidden="true" />
          <div class="topology-node primary"><Network :size="17" /><strong>{{ modeLabel }}处理</strong><span>{{ props.rules.rules.length }} 条规则</span></div>
          <ChevronRight class="topology-link" :size="18" aria-hidden="true" />
          <div class="topology-node"><Server :size="17" /><strong>{{ routeTarget.title }}</strong><span>{{ routeTarget.detail }}</span></div>
        </div>
        <p class="topology-caption">当前优先规则：{{ ruleHint }}</p>
      </article>
    </section>
  </section>
</template>
