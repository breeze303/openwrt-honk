<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import {
  Check,
  ChevronDown,
  CircleAlert,
  CloudDownload,
  Gauge,
  Link,
  Pencil,
  Plus,
  RefreshCw,
  Search,
  Server,
  Trash2,
  Upload,
  Wifi,
  WifiOff,
  X,
} from '@lucide/vue'
import {
  api,
  type ConfigModel,
  type NodeTestResponse,
  type ParsedNode,
  type ProxyInfo,
  type StateResponse,
  type SubscriptionStatus,
} from '../api'

const props = defineProps<{
  running: boolean
  proxies: Record<string, ProxyInfo>
  subscriptions: SubscriptionStatus[]
  busy: boolean
}>()
const emit = defineEmits<{
  select: [group: string, name: string]
  testProxy: [name: string, url: string]
  testGroup: [name: string, url: string]
  refreshSubscription: [name: string]
  changed: []
}>()

const model = ref<ConfigModel | null>(null)
const state = ref<StateResponse | null>(null)
const loading = ref(true)
const mutating = ref(false)
const error = ref('')
const message = ref('')
const search = ref('')
const nodeLink = ref('')
const subscriptionName = ref('')
const subscriptionUrl = ref('')
const subscriptionInterval = ref('86400')
const testUrl = ref('https://www.gstatic.com/generate_204')
const selectedNode = ref<ParsedNode | null>(null)
const nodeDraft = ref<ParsedNode | null>(null)
const nodeTest = ref<NodeTestResponse | null>(null)
const showSecrets = ref(false)
const expandedGroups = ref<Set<string>>(new Set())

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T
}

function normalizeModel(input: ConfigModel): ConfigModel {
  const routing = input.routing || { rules: [], fallback: 'direct' }
  const dns = input.dns || { raw: '', upstreams: [] }
  return {
    ...input,
    nodes: Array.isArray(input.nodes) ? input.nodes : [],
    groups: Array.isArray(input.groups) ? input.groups : [],
    subscriptions: Array.isArray(input.subscriptions) ? input.subscriptions : [],
    routing: {
      ...routing,
      rules: Array.isArray(routing.rules) ? routing.rules : [],
    },
    dns: {
      ...dns,
      upstreams: Array.isArray(dns.upstreams) ? dns.upstreams : [],
    },
  }
}

function quote(value: string): string {
  return `'${value.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

type Bounds = { start: number; open: number; close: number }
function blockBounds(source: string, name: string): Bounds | null {
  const match = new RegExp(`(?:^|\\n)([ \\t]*)${escapeRegExp(name)}\\s*\\{`, 'm').exec(source)
  if (!match || match.index < 0) return null
  const start = match.index + (match[0].startsWith('\n') ? 1 : 0) + match[1].length
  const open = source.indexOf('{', match.index)
  let depth = 0
  let quoteChar = ''
  let escaped = false
  let comment = false
  for (let index = open; index < source.length; index += 1) {
    const char = source[index]
    if (comment) {
      if (char === '\n') comment = false
      continue
    }
    if (quoteChar) {
      if (escaped) escaped = false
      else if (char === '\\') escaped = true
      else if (char === quoteChar) quoteChar = ''
      continue
    }
    if (char === '#') { comment = true; continue }
    if (char === "'" || char === '"') { quoteChar = char; continue }
    if (char === '{') depth += 1
    if (char === '}' && --depth === 0) return { start, open, close: index }
  }
  return null
}

function removeNamedBlock(source: string, section: string, name: string): string {
  const outer = blockBounds(source, section)
  if (!outer) return source
  const body = source.slice(outer.open + 1, outer.close)
  const inner = blockBounds(body, name)
  if (inner) {
    const nextBody = body.slice(0, inner.start).replace(/\s*$/, '\n') + body.slice(inner.close + 1)
    return source.slice(0, outer.open + 1) + nextBody + source.slice(outer.close)
  }
  const line = new RegExp(`\\n?[ \\t]*${escapeRegExp(name)}\\s*:\\s*[^\\n#]*(?:\\n|$)`, 'm')
  const nextBody = body.replace(line, '\n')
  return source.slice(0, outer.open + 1) + nextBody + source.slice(outer.close)
}

function putNamedBlock(source: string, section: string, name: string, body: string): string {
  const replacement = `    ${name} {\n${body.trimEnd()}\n    }`
  const outer = blockBounds(source, section)
  if (!outer) {
    return `${source.trimEnd()}\n\n${section} {\n${replacement}\n}\n`
  }
  const without = removeNamedBlock(source, section, name)
  const nextOuter = blockBounds(without, section)
  if (!nextOuter) return without
  const outerBody = without.slice(nextOuter.open + 1, nextOuter.close)
  const trimmed = outerBody.trimEnd()
  const separator = trimmed ? '\n\n' : '\n'
  const nextBody = `${trimmed}${separator}${replacement}\n`
  return without.slice(0, nextOuter.open + 1) + nextBody + without.slice(nextOuter.close)
}

function removeNodeEntry(source: string, name: string): string {
  const bounds = blockBounds(source, 'node')
  if (!bounds) return source
  const body = source.slice(bounds.open + 1, bounds.close)
  const line = new RegExp(`\\n?[ \\t]*${escapeRegExp(name)}\\s*:\\s*[^\\n#]*(?:\\n|$)`, 'm')
  return source.slice(0, bounds.open + 1) + body.replace(line, '\n') + source.slice(bounds.close)
}

function replaceNodeEntry(source: string, oldName: string, node: ParsedNode): string {
  const lineText = `    ${node.name}: ${quote(node.raw)}`
  const bounds = blockBounds(source, 'node')
  if (!bounds) return `${source.trimEnd()}\n\nnode {\n${lineText}\n}\n`
  const body = source.slice(bounds.open + 1, bounds.close)
  const line = new RegExp(`(^|\\n)([ \\t]*)${escapeRegExp(oldName)}\\s*:\\s*[^\\n#]*`, 'm')
  const nextBody = line.test(body)
    ? body.replace(line, (_all, prefix) => `${prefix}${lineText}`)
    : `${body.trimEnd()}\n${lineText}\n`
  return source.slice(0, bounds.open + 1) + nextBody + source.slice(bounds.close)
}

function updateNodeLink(node: ParsedNode): string {
  const [withoutHash, hash = ''] = node.raw.split('#', 2)
  const [authority, query = ''] = withoutHash.split('?', 2)
  const scheme = (node.protocol || authority.split('://', 1)[0]).toLowerCase()
  const prefix = authority.match(/^[\w+.-]+:\/\//)?.[0] || `${scheme}://`
  const originalAuthority = authority.slice(prefix.length)
  const at = originalAuthority.lastIndexOf('@')
  let credential = at >= 0 ? originalAuthority.slice(0, at) : ''
  if (scheme === 'anytls' && node.password) credential = encodeURIComponent(node.password)
  const params = new URLSearchParams(query)
  if (node.sni) params.set('sni', node.sni); else params.delete('sni')
  if (node.network) params.set('type', node.network); else params.delete('type')
  if (node.insecure) { params.set('insecure', '1'); params.set('allowInsecure', '1') }
  else { params.delete('insecure'); params.delete('allowInsecure') }
  const host = node.host.includes(':') ? `[${node.host}]` : node.host
  const suffix = params.toString()
  return `${prefix}${credential ? `${credential}@` : ''}${host}:${node.port}${suffix ? `?${suffix}` : ''}${hash ? `#${hash}` : ''}`
}

function manualGroup(source: string, nodes: ParsedNode[]): string {
  let next = removeNamedBlock(source, 'group', 'manual')
  const names = nodes.filter(node => !node.runtime).map(node => node.name)
  if (!names.length) return next
  const members = names.map(quote).join(', ')
  return putNamedBlock(next, 'group', 'manual', `        filter: name(${members})\n        policy: selector\n        final: direct`)
}

function subscriptionGroup(source: string, name: string, enabled = true): string {
  const next = removeNamedBlock(source, 'group', name)
  if (!enabled) return next
  return putNamedBlock(next, 'group', name, `        filter: subscription(${quote(name)})\n        policy: selector\n        final: direct`)
}

function subscriptionEntry(source: string, name: string, url: string, interval: number, enabled: boolean): string {
  let next = removeNamedBlock(source, 'subscription', name)
  const section = blockBounds(next, 'subscription')
  const replacement = `    ${name} {\n        url: ${quote(url)}\n        update_interval: ${Math.max(0, interval)}\n        enabled: ${enabled}\n    }`
  if (!section) return `${next.trimEnd()}\n\nsubscription {\n${replacement}\n}\n`
  const body = next.slice(section.open + 1, section.close)
  const trimmed = body.trimEnd()
  return next.slice(0, section.open + 1) + `${trimmed}${trimmed ? '\n\n' : '\n'}${replacement}\n` + next.slice(section.close)
}

function removeSubscription(source: string, name: string): string {
  return removeNamedBlock(source, 'subscription', name)
}

function slugName(value: string, fallback: string): string {
  const slug = value.trim().replace(/[^A-Za-z0-9_.-]+/g, '-').replace(/^-+|-+$/g, '')
  return slug || fallback
}

function delay(name: string): number {
  const history = props.proxies[name]?.history || []
  return history.length ? history[history.length - 1].delay : 0
}

function isPrimaryNode(name: string) {
  const proxy = props.proxies[name]
  const type = proxy?.type.toLowerCase()
  return Boolean(proxy) && !Array.isArray(proxy.all) && type !== 'direct' && type !== 'block'
}

const allRuntimeGroups = computed(() => Object.values(props.proxies)
  .filter(item => Array.isArray(item.all))
  .filter(item => item.name !== 'GLOBAL'))
const runtimeGroups = computed(() => allRuntimeGroups.value
  .filter(item => `${item.name} ${item.all?.join(' ')}`.toLowerCase().includes(search.value.trim().toLowerCase())))
const groupedNodeNames = computed(() => new Set(allRuntimeGroups.value.flatMap(group => group.all || [])))
const standaloneNodes = computed(() => Object.values(props.proxies)
  .filter(item => isPrimaryNode(item.name) && !groupedNodeNames.value.has(item.name))
  .filter(item => item.name.toLowerCase().includes(search.value.trim().toLowerCase())))
const primaryNodeName = computed(() => {
  const name = props.proxies.GLOBAL?.now || ''
  return isPrimaryNode(name) ? name : ''
})
const configuredSubscriptions = computed(() => model.value?.subscriptions || [])
const displayGroups = computed(() => {
  const groups = new Map(runtimeGroups.value.map(group => [group.name, group]))
  for (const subscription of configuredSubscriptions.value) {
    if (!groups.has(subscription.name)) {
      groups.set(subscription.name, { name: subscription.name, type: 'Subscription', all: [] })
    }
  }
  const term = search.value.trim().toLowerCase()
  return [...groups.values()].filter(group => {
    const subscription = configuredSubscriptions.value.find(item => item.name === group.name)
    const contents = [group.name, subscription?.url || '', ...(group.all || [])].join(' ').toLowerCase()
    return !term || contents.includes(term)
  })
})

function statusFor(name: string) {
  return props.subscriptions.find(item => item.name === name)
}

function setPrimaryNode(name: string) {
  if (isPrimaryNode(name)) emit('select', 'GLOBAL', name)
}

function groupUsesPrimary(group: ProxyInfo) {
  return Boolean(primaryNodeName.value) && Boolean(group.all?.includes(primaryNodeName.value))
}

function isGroupExpanded(name: string) {
  return expandedGroups.value.has(name)
}

function toggleGroup(name: string) {
  const next = new Set(expandedGroups.value)
  if (next.has(name)) next.delete(name)
  else next.add(name)
  expandedGroups.value = next
}

function configuredSubscription(name: string) {
  return configuredSubscriptions.value.find(item => item.name === name)
}

function changeSubscriptionIntervalFor(name: string, event: Event) {
  const subscription = configuredSubscription(name)
  if (subscription) changeSubscriptionInterval(subscription, event)
}

function toggleSubscriptionFor(name: string, event: Event) {
  const subscription = configuredSubscription(name)
  if (subscription) toggleSubscription(subscription, event)
}

function renameSubscriptionFor(name: string) {
  const subscription = configuredSubscription(name)
  if (subscription) void renameSubscription(subscription)
}

function formatUpdated(value?: string | null) {
  if (!value) return '尚未更新'
  const date = new Date(value)
  return Number.isNaN(date.valueOf()) ? value : date.toLocaleString()
}

function subscriptionHost(url: string) {
  try { return new URL(url).hostname } catch { return '远程订阅' }
}

function configuredNode(name: string) {
  return model.value?.nodes.find(node => node.name === name)
}

function editConfiguredNode(name: string) {
  const node = configuredNode(name)
  if (node) editNode(node)
}

function deleteConfiguredNode(name: string) {
  const node = configuredNode(name)
  if (node) void deleteNode(node)
}

async function loadConfig() {
  loading.value = true
  error.value = ''
  try {
    const [nextState, nextModel] = await Promise.all([api.state(), api.model()])
    state.value = nextState
    model.value = normalizeModel(nextModel.model)
  } catch (reason) {
    error.value = (reason as Error).message
  } finally {
    loading.value = false
  }
}

async function applyConfig(config: string, success: string) {
  if (!state.value) await loadConfig()
  if (!state.value) return
  mutating.value = true
  error.value = ''
  message.value = ''
  try {
    await api.modelApply(config, state.value.diskRevision)
    await loadConfig()
    message.value = success
    emit('changed')
  } catch (reason) {
    error.value = (reason as Error).message
  } finally {
    mutating.value = false
  }
}

async function importNode() {
  const link = nodeLink.value.trim()
  if (!link || !model.value) return
  mutating.value = true
  error.value = ''
  try {
    const result = await api.parseNode(link)
    const node = { ...result.node, raw: link }
    const duplicate = model.value.nodes.find(item => item.name === node.name)
    if (duplicate) throw new Error(`节点名称已存在：${node.name}`)
    const nodes = [...model.value.nodes, node]
    const config = manualGroup(replaceNodeEntry(model.value.rawConfig, '__missing__', node), nodes)
    await applyConfig(config, '节点已添加并应用')
    nodeLink.value = ''
  } catch (reason) {
    error.value = (reason as Error).message
    mutating.value = false
  }
}

async function addSubscription() {
  if (!model.value) return
  const url = subscriptionUrl.value.trim()
  if (!/^https?:\/\//i.test(url)) { error.value = '请输入有效的 HTTP/HTTPS 订阅链接。'; return }
  let fallback = 'subscription'
  try { fallback = new URL(url).hostname.replace(/^www\./i, '') || fallback } catch { /* validation above handles this */ }
  let name = slugName(subscriptionName.value, fallback)
  let suffix = 2
  while (model.value.subscriptions.some(item => item.name === name) || model.value.groups.some(item => item.name === name) || model.value.nodes.some(item => item.name === name)) {
    name = `${slugName(subscriptionName.value, fallback)}-${suffix++}`
  }
  const interval = Number(subscriptionInterval.value)
  let config = subscriptionEntry(model.value.rawConfig, name, url, Number.isFinite(interval) ? interval : 86400, true)
  config = subscriptionGroup(config, name)
  await applyConfig(config, '订阅已添加，正在拉取节点')
  subscriptionName.value = ''
  subscriptionUrl.value = ''
}

async function deleteSubscription(subscription: { name: string }) {
  if (!model.value || !window.confirm(`确认删除订阅“${subscription.name}”吗？`)) return
  let config = removeSubscription(model.value.rawConfig, subscription.name)
  config = removeNamedBlock(config, 'group', subscription.name)
  await applyConfig(config, '订阅已删除')
}

async function renameSubscription(subscription: { name: string; url: string; updateInterval?: number; enabled?: boolean }) {
  if (!model.value) return
  const nextName = window.prompt('输入新的订阅名称', subscription.name)
  if (!nextName || nextName === subscription.name) return
  const name = slugName(nextName, subscription.name)
  if (model.value.subscriptions.some(item => item.name === name && item.name !== subscription.name) || model.value.groups.some(item => item.name === name)) {
    error.value = '名称已存在，请使用其他名称。'
    return
  }
  let config = removeSubscription(model.value.rawConfig, subscription.name)
  config = removeNamedBlock(config, 'group', subscription.name)
  config = subscriptionEntry(config, name, subscription.url, subscription.updateInterval ?? 86400, subscription.enabled !== false)
  config = subscriptionGroup(config, name)
  await applyConfig(config, '订阅名称已更新')
}

async function updateSubscriptionOptions(
  subscription: { name: string; url: string; updateInterval?: number; enabled?: boolean },
  interval: number,
  enabled: boolean,
) {
  if (!model.value) return
  let config = subscriptionEntry(model.value.rawConfig, subscription.name, subscription.url, interval, enabled)
  config = subscriptionGroup(config, subscription.name, enabled)
  await applyConfig(config, enabled ? '订阅设置已更新' : '订阅已停用')
}

function changeSubscriptionInterval(subscription: { name: string; url: string; updateInterval?: number; enabled?: boolean }, event: Event) {
  const interval = Number((event.target as HTMLSelectElement).value)
  void updateSubscriptionOptions(subscription, Number.isFinite(interval) ? interval : 86400, subscription.enabled !== false)
}

function toggleSubscription(subscription: { name: string; url: string; updateInterval?: number; enabled?: boolean }, event: Event) {
  void updateSubscriptionOptions(subscription, subscription.updateInterval ?? 86400, (event.target as HTMLInputElement).checked)
}

async function deleteNode(node: ParsedNode) {
  if (!model.value || !window.confirm(`确认删除节点“${node.name}”吗？`)) return
  const nodes = model.value.nodes.filter(item => item.name !== node.name)
  const config = manualGroup(removeNodeEntry(model.value.rawConfig, node.name), nodes)
  await applyConfig(config, '节点已删除')
}

function editNode(node: ParsedNode) {
  if (!node.raw) return
  selectedNode.value = node
  nodeDraft.value = clone(node)
}

async function saveNode() {
  if (!model.value || !selectedNode.value || !nodeDraft.value) return
  const next = clone(nodeDraft.value)
  next.raw = updateNodeLink(next)
  const nodes = model.value.nodes.map(item => item === selectedNode.value ? next : item)
  const config = manualGroup(replaceNodeEntry(model.value.rawConfig, selectedNode.value.name, next), nodes)
  await applyConfig(config, '节点已更新')
  selectedNode.value = null
  nodeDraft.value = null
}

onMounted(() => { void loadConfig() })
</script>

<template>
  <section class="view-stack proxies-view node-selection-view">
    <header class="view-heading proxy-heading">
      <div>
        <p class="eyebrow">节点与订阅</p>
        <h1>节点选择</h1>
        <span class="page-subtitle">选择主节点，规则代理与全局代理共用同一出口</span>
      </div>
      <div class="view-tools">
        <label class="search-control">
          <Search :size="17" />
          <input v-model="search" aria-label="搜索节点或订阅" placeholder="搜索节点或订阅" />
        </label>
        <label class="compact-field"><span>测速地址</span><input v-model="testUrl" type="url" /></label>
      </div>
    </header>

    <p v-if="error" class="inline-error" role="alert"><CircleAlert :size="16" />{{ error }}<button class="icon-button" aria-label="关闭错误" title="关闭错误" @click="error = ''"><X :size="15" /></button></p>
    <p v-if="message" class="inline-success" role="status"><Check :size="16" />{{ message }}</p>

    <section class="surface-panel intake-panel">
      <form class="intake-row" @submit.prevent="importNode">
        <div class="intake-title"><span class="intake-icon"><Upload :size="18" /></span><div><p class="eyebrow">手动节点</p><strong>导入链接</strong></div></div>
        <label class="intake-field"><span>节点链接</span><input v-model="nodeLink" placeholder="ss://、trojan://、anytls://…" /></label>
        <button class="primary-button" type="submit" :disabled="mutating || !nodeLink.trim()"><Plus :size="17" />添加节点</button>
      </form>
      <form class="intake-row subscription-intake" @submit.prevent="addSubscription">
        <div class="intake-title"><span class="intake-icon"><CloudDownload :size="18" /></span><div><p class="eyebrow">远程节点源</p><strong>添加订阅</strong></div></div>
        <label class="intake-field short"><span>名称</span><input v-model="subscriptionName" placeholder="留空使用域名" /></label>
        <label class="intake-field"><span>订阅链接</span><input v-model="subscriptionUrl" type="url" placeholder="https://example.com/subscribe" /></label>
        <label class="intake-field interval"><span>更新周期</span><select v-model="subscriptionInterval"><option value="0">仅手动</option><option value="900">15 分钟</option><option value="3600">1 小时</option><option value="21600">6 小时</option><option value="43200">12 小时</option><option value="86400">24 小时</option></select></label>
        <button class="primary-button" type="submit" :disabled="mutating || !subscriptionUrl.trim()"><Link :size="17" />添加订阅</button>
      </form>
    </section>

    <div v-if="loading" class="empty-state"><RefreshCw :size="22" class="spin" /><strong>正在读取节点配置</strong></div>
    <template v-else>
      <div v-if="!running" class="empty-state compact-empty"><WifiOff :size="22" /><strong>服务未运行</strong><span>节点和订阅已保存；启动 Honk 后可切换节点并测试延迟。</span></div>
      <section v-if="running" class="surface-panel proxy-group primary-node-panel">
        <header class="panel-heading proxy-group-heading">
          <div><p class="eyebrow">统一出口</p><h2>主节点</h2><span>{{ primaryNodeName || '尚未选择' }} · 规则代理与全局代理共用</span></div>
          <span v-if="primaryNodeName" class="active-chip"><Check :size="13" />使用中</span>
        </header>
        <p class="panel-note">在下方订阅组或手动节点中选择一个节点，即可更新主节点。</p>
      </section>
      <section v-if="running && standaloneNodes.length" class="surface-panel proxy-group">
        <header class="panel-heading proxy-group-heading">
          <div><p class="eyebrow">手动节点</p><h2>未分组节点</h2><span>{{ standaloneNodes.length }} 个成员</span></div>
        </header>
        <div class="proxy-node-list">
          <div v-for="node in standaloneNodes" :key="node.name" class="proxy-node" :class="{ selected: primaryNodeName === node.name, dead: delay(node.name) === 0 }">
            <button class="proxy-select" :disabled="busy" title="设为主节点" @click="setPrimaryNode(node.name)"><span class="proxy-node-icon"><Server :size="17" /></span><span class="proxy-node-copy"><strong>{{ node.name }}</strong><small>{{ primaryNodeName === node.name ? `${node.type} · 主节点` : node.type }}</small></span><span class="latency" :class="{ good: delay(node.name) > 0 && delay(node.name) < 180, slow: delay(node.name) >= 500 }"><Wifi v-if="delay(node.name)" :size="14" /><WifiOff v-else :size="14" />{{ delay(node.name) ? `${delay(node.name)} ms` : '未测试' }}</span></button><button class="node-test icon-button" :disabled="busy" title="测试此节点" aria-label="测试此节点" @click="emit('testProxy', node.name, testUrl)"><Gauge :size="16" /></button><div v-if="configuredNode(node.name)" class="node-manage"><button class="icon-button" title="编辑节点" aria-label="编辑节点" @click="editConfiguredNode(node.name)"><Pencil :size="15" /></button><button class="icon-button danger-icon" title="删除节点" aria-label="删除节点" @click="deleteConfiguredNode(node.name)"><Trash2 :size="15" /></button></div>
          </div>
        </div>
      </section>
      <section v-if="displayGroups.length" class="proxy-groups">
        <section v-for="group in displayGroups" :key="group.name" class="surface-panel proxy-group">
          <header class="subscription-group-header">
            <button class="group-toggle" type="button" :aria-expanded="isGroupExpanded(group.name)" @click="toggleGroup(group.name)">
              <span class="group-toggle-icon"><CloudDownload v-if="configuredSubscription(group.name)" :size="18" /><Server v-else :size="18" /></span>
              <span class="group-toggle-copy"><span class="eyebrow">{{ configuredSubscription(group.name) ? '订阅节点组' : group.name === 'manual' ? '手动节点组' : group.type }}</span><strong>{{ group.name === 'manual' ? '手动节点' : group.name }}</strong><small>{{ configuredSubscription(group.name) ? subscriptionHost(configuredSubscription(group.name)?.url || '') : groupUsesPrimary(group) ? '主节点：' + primaryNodeName : (group.all?.length || 0) + ' 个成员' }}</small></span>
              <span class="group-summary"><span :class="['subscription-state', statusFor(group.name)?.state || 'idle']"><CircleAlert v-if="statusFor(group.name)?.state === 'error'" :size="14" /><Check v-else-if="statusFor(group.name)?.state === 'ready'" :size="14" /><span v-else class="state-dot" />{{ statusFor(group.name)?.nodeCount || group.all?.length || 0 }} 个节点</span><ChevronDown :size="18" :class="{ expanded: isGroupExpanded(group.name) }" /></span>
            </button>
            <div class="group-actions">
              <template v-if="configuredSubscription(group.name)">
                <select :value="configuredSubscription(group.name)?.updateInterval ?? 86400" aria-label="自动更新周期" :disabled="mutating" @change="changeSubscriptionIntervalFor(group.name, $event)"><option :value="0">手动</option><option :value="900">15 分钟</option><option :value="3600">1 小时</option><option :value="21600">6 小时</option><option :value="43200">12 小时</option><option :value="86400">24 小时</option></select>
                <label class="switch-control"><input type="checkbox" :checked="configuredSubscription(group.name)?.enabled !== false" :disabled="mutating" @change="toggleSubscriptionFor(group.name, $event)" /><span>启用</span></label>
                <button class="icon-button" :disabled="busy || mutating || !running || configuredSubscription(group.name)?.enabled === false" title="立即更新订阅" aria-label="立即更新订阅" @click="emit('refreshSubscription', group.name)"><RefreshCw :size="16" /></button>
                <button class="icon-button" title="重命名订阅" aria-label="重命名订阅" @click="renameSubscriptionFor(group.name)"><Pencil :size="16" /></button>
                <button class="icon-button danger-icon" title="删除订阅" aria-label="删除订阅" @click="deleteSubscription({ name: group.name })"><Trash2 :size="16" /></button>
              </template>
              <button class="icon-button" :disabled="busy || !running || !(group.all?.length)" title="测试整个代理组" aria-label="测试整个代理组" @click="emit('testGroup', group.name, testUrl)"><Gauge :size="18" /></button>
            </div>
          </header>
          <Transition name="group-expand">
            <div v-if="isGroupExpanded(group.name)" class="proxy-node-list">
            <div v-for="name in group.all" :key="name" class="proxy-node" :class="{ selected: primaryNodeName === name, dead: delay(name) === 0 }">
              <button class="proxy-select" :disabled="busy || !isPrimaryNode(name)" title="设为主节点" @click="setPrimaryNode(name)"><span class="proxy-node-icon"><Server :size="17" /></span><span class="proxy-node-copy"><strong>{{ name }}</strong><small>{{ primaryNodeName === name ? `${props.proxies[name]?.type || 'Proxy'} · 主节点` : props.proxies[name]?.type || 'Proxy' }}</small></span><span class="latency" :class="{ good: delay(name) > 0 && delay(name) < 180, slow: delay(name) >= 500 }"><Wifi v-if="delay(name)" :size="14" /><WifiOff v-else :size="14" />{{ delay(name) ? `${delay(name)} ms` : '未测试' }}</span></button><button class="node-test icon-button" :disabled="busy" title="测试此节点" aria-label="测试此节点" @click="emit('testProxy', name, testUrl)"><Gauge :size="16" /></button><div v-if="configuredNode(name)" class="node-manage"><button class="icon-button" title="编辑节点" aria-label="编辑节点" @click="editConfiguredNode(name)"><Pencil :size="15" /></button><button class="icon-button danger-icon" title="删除节点" aria-label="删除节点" @click="deleteConfiguredNode(name)"><Trash2 :size="15" /></button></div></div>
              <div v-if="!group.all?.length" class="subscription-group-empty"><CloudDownload :size="18" /><span>{{ running ? '此订阅暂未返回节点，请更新订阅后重试。' : '服务停止，启动 Honk 后加载订阅节点。' }}</span></div>
            </div>
          </Transition>
        </section>
      </section>
      <div v-else-if="running && !standaloneNodes.length" class="empty-state"><Server :size="22" /><strong>还没有可用节点</strong><span>先导入分享链接或添加订阅。</span></div>
    </template>

    <section v-if="nodeDraft" class="modal-backdrop"><div class="modal node-edit-modal"><div class="panel-title"><h2>编辑节点</h2><button class="icon-button" aria-label="关闭编辑" title="关闭编辑" @click="nodeDraft = null; selectedNode = null"><X :size="17" /></button></div><div class="form-grid"><label><span>名称</span><input v-model="nodeDraft.name" /></label><label><span>服务器</span><input v-model="nodeDraft.host" /></label><label><span>端口</span><input v-model.number="nodeDraft.port" type="number" /></label><label><span>SNI</span><input v-model="nodeDraft.sni" /></label><label><span>传输</span><input v-model="nodeDraft.network" /></label><label class="wide"><span>密码/凭据</span><input v-model="nodeDraft.password" :type="showSecrets ? 'text' : 'password'" /></label><label class="check wide"><input v-model="showSecrets" type="checkbox" />显示凭据</label></div><div class="modal-actions"><button class="secondary-button" @click="nodeDraft = null; selectedNode = null">取消</button><button class="primary-button" :disabled="mutating" @click="saveNode"><Check :size="16" />保存并应用</button></div></div></section>
    <section v-if="nodeTest" class="test-result" :class="{ failed: !nodeTest.passed }"><strong>{{ nodeTest.passed ? '测速通过' : '测速失败' }} · {{ nodeTest.node.name }}</strong><span>{{ nodeTest.summary }}</span><pre>{{ nodeTest.output }}</pre></section>
  </section>
</template>
