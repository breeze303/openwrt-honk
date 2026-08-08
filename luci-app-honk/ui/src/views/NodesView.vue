<script setup lang="ts">
import { computed, ref } from 'vue'
import { ChevronDown, ChevronRight, Gauge, Link, Plus, RadioTower, RefreshCw, Trash2, Waypoints, X } from '@lucide/vue'
import { api } from '../api'
import { t } from '../i18n'
import type { NodeDelay, RuntimeNodeItem, SourceItem, SourceKind, StateResponse } from '../types'

const props = defineProps<{ state: StateResponse | null }>()
const emit = defineEmits<{ changed: []; notice: [message: string]; error: [message: string] }>()
const kind = ref<SourceKind>('node')
const name = ref('')
const url = ref('')
const formOpen = ref(false)
const busy = ref(false)
const checkingAll = ref(false)
const checkedCount = ref(0)
const collapsedSubscriptions = ref<Record<string, boolean>>({})
const delays = ref<Record<string, NodeDelay>>({})

const allSources = computed(() => [
  ...(Array.isArray(props.state?.catalog?.nodes) ? props.state.catalog.nodes : []),
  ...(Array.isArray(props.state?.catalog?.subscriptions) ? props.state.catalog.subscriptions : []),
])
const runtimeNodes = computed(() => Array.isArray(props.state?.catalog?.subscriptionNodes) ? props.state.catalog.subscriptionNodes : [])
const subscriptionGroups = computed(() => {
  const sources = Array.isArray(props.state?.catalog?.subscriptions) ? props.state.catalog.subscriptions : []
  const groups: Array<{ name: string; source?: SourceItem; nodes: RuntimeNodeItem[] }> = sources.map(source => ({
    name: source.name,
    source,
    nodes: runtimeNodes.value.filter(item => item.subscription === source.name),
  }))
  const claimed = new Set(groups.flatMap(group => group.nodes.map(item => item.name)))
  const unassigned = runtimeNodes.value.filter(item => !claimed.has(item.name))
  if (unassigned.length) groups.push({ name: t('unassignedNodes'), nodes: unassigned })
  return groups
})
const nodes = computed(() => [
  ...(Array.isArray(props.state?.catalog?.nodes) ? props.state.catalog.nodes : []).map(item => ({ name: item.name, protocol: item.protocol, source: item.kind })),
  ...runtimeNodes.value.map(item => ({ name: item.name, protocol: item.protocol, source: item.subscription })),
])

function resultFor(nodeName: string): NodeDelay {
  return delays.value[nodeName] || { status: 'idle' }
}

function resultTitle(nodeName: string): string | undefined {
  const result = resultFor(nodeName)
  return result.status === 'error' ? result.error : undefined
}

function isSubscriptionCollapsed(subscriptionName: string): boolean {
  return collapsedSubscriptions.value[subscriptionName] !== false
}

function toggleSubscription(subscriptionName: string) {
  collapsedSubscriptions.value = {
    ...collapsedSubscriptions.value,
    [subscriptionName]: !isSubscriptionCollapsed(subscriptionName),
  }
}

function closeComposer() {
  formOpen.value = false
}

async function checkNode(nodeName: string) {
  delays.value = { ...delays.value, [nodeName]: { status: 'testing' } }
  try {
    const result = await api.delay(nodeName)
    delays.value = { ...delays.value, [nodeName]: { status: 'ok', delay: result.delay } }
  } catch (reason) {
    delays.value = { ...delays.value, [nodeName]: { status: 'error', error: (reason as Error).message } }
  }
}

async function checkAll() {
  if (checkingAll.value || nodes.value.length === 0) return
  checkingAll.value = true
  checkedCount.value = 0
  const candidates = nodes.value.map(item => item.name)
  let cursor = 0
  const worker = async () => {
    while (cursor < candidates.length) {
      const nodeName = candidates[cursor]
      cursor += 1
      await checkNode(nodeName)
      checkedCount.value += 1
    }
  }
  try {
    await Promise.all(Array.from({ length: Math.min(4, candidates.length) }, () => worker()))
  } finally {
    checkingAll.value = false
  }
}

async function mutate(action: string, itemName: string, itemUrl = '') {
  if (!props.state) return
  busy.value = true
  try {
    await api.mutateSource({ action, name: itemName, url: itemUrl, expectedRevision: props.state.revision })
    name.value = ''
    url.value = ''
    formOpen.value = false
    emit('notice', t('updated'))
    emit('changed')
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    busy.value = false
  }
}

function addSource() {
  if (!name.value.trim() || !url.value.trim()) return
  const action = kind.value === 'node' ? 'add-node' : 'add-subscription'
  void mutate(action, name.value.trim(), url.value.trim())
}

function removeSource(itemKind: SourceKind, itemName: string) {
  if (!window.confirm(`${t('remove')} ${itemName}?`)) return
  void mutate(itemKind === 'node' ? 'remove-node' : 'remove-subscription', itemName)
}

async function refreshSubscription(subscriptionName: string) {
  busy.value = true
  try {
    await api.refreshSubscription(subscriptionName)
    emit('notice', t('refreshSubscription'))
    for (let attempt = 0; attempt < 4; attempt += 1) {
      await new Promise(resolve => window.setTimeout(resolve, 900))
      emit('changed')
    }
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="page nodes-page">
    <header class="nodes-toolbar">
      <div class="nodes-summary">
        <span class="count-label">{{ allSources.length }}</span><span>{{ t('source') }}</span>
        <span class="toolbar-divider" aria-hidden="true" />
        <span class="count-label">{{ runtimeNodes.length }}</span><span>{{ t('subscriptionNodes') }}</span>
      </div>
      <div class="nodes-toolbar-actions">
        <button class="secondary-button compact-command" type="button" :disabled="checkingAll || nodes.length === 0" @click="checkAll"><Gauge :size="16" />{{ checkingAll ? `${t('checkingLatency')} ${checkedCount}/${nodes.length}` : t('checkAllLatency') }}</button>
        <button class="primary-command compact-command" type="button" :disabled="busy" @click="formOpen = !formOpen"><Plus :size="16" />{{ t('add') }}</button>
      </div>
    </header>

    <section v-if="formOpen" class="source-composer" :aria-labelledby="kind === 'node' ? 'add-node-heading' : 'add-subscription-heading'">
      <div class="segmented composer-kind" role="group" :aria-label="t('type')">
        <button type="button" :class="{ active: kind === 'node' }" :aria-pressed="kind === 'node'" @click="kind = 'node'"><Waypoints :size="16" />{{ t('nodes') }}</button>
        <button type="button" :class="{ active: kind === 'subscription' }" :aria-pressed="kind === 'subscription'" @click="kind = 'subscription'"><RadioTower :size="16" />{{ t('addSubscription') }}</button>
      </div>
      <label class="composer-name"><span :id="kind === 'node' ? 'add-node-heading' : 'add-subscription-heading'">{{ t('name') }}</span><input v-model="name" autocomplete="off" maxlength="64" /></label>
      <label class="composer-link"><span>{{ t('link') }}</span><input v-model="url" autocomplete="off" spellcheck="false" /></label>
      <button class="primary-command compact-command" type="button" :disabled="busy || !name.trim() || !url.trim()" @click="addSource"><Plus :size="16" />{{ t('add') }}</button>
      <button class="icon-button" type="button" :title="t('close')" :aria-label="t('close')" @click="closeComposer"><X :size="16" /></button>
    </section>

    <section class="source-table" aria-live="polite">
      <article v-for="item in allSources" :key="`${item.kind}:${item.name}`" class="source-row horizontal-row">
        <span class="source-icon"><RadioTower v-if="item.kind === 'subscription'" :size="17" /><Waypoints v-else :size="17" /></span>
        <div class="source-identity"><strong>{{ item.name }}</strong><span>{{ item.kind }} · {{ item.protocol }}</span></div>
        <span v-if="item.cacheSource" class="status-tag cache-source">{{ item.cacheSource === 'missing' ? t('missingCache') : (item.cacheSource === 'stale' ? t('staleCache') : t('cached')) }}</span>
        <span v-else-if="item.kind === 'subscription' && item.enabled === false" class="status-tag">off</span>
        <span v-else-if="item.kind === 'subscription' && item.cachedError" class="status-tag cache-error">{{ t('cacheError') }}</span>
        <span v-else-if="item.kind === 'node'" class="latency-tag" :class="`latency-${resultFor(item.name).status}`" :title="resultTitle(item.name)">
          <RefreshCw v-if="resultFor(item.name).status === 'testing'" :size="14" class="spin" />
          <template v-else-if="resultFor(item.name).status === 'ok'">{{ resultFor(item.name).delay }} ms</template>
          <template v-else-if="resultFor(item.name).status === 'error'">{{ t('latencyFailed') }}</template>
          <template v-else>—</template>
        </span>
        <span v-else />
        <div class="row-actions">
          <button v-if="item.kind === 'subscription'" class="icon-button" type="button" :title="t('refreshSubscription')" :aria-label="`${t('refreshSubscription')} ${item.name}`" :disabled="busy" @click="refreshSubscription(item.name)"><RefreshCw :size="16" :class="{ spin: busy }" /></button>
          <button v-if="item.kind === 'node'" class="icon-button" type="button" :title="t('checkLatency')" :aria-label="`${t('checkLatency')} ${item.name}`" :disabled="checkingAll || resultFor(item.name).status === 'testing'" @click="checkNode(item.name)"><Gauge :size="16" /></button>
          <button class="icon-button danger" type="button" :title="t('remove')" :aria-label="`${t('remove')} ${item.name}`" :disabled="busy" @click="removeSource(item.kind, item.name)"><Trash2 :size="16" /></button>
        </div>
      </article>
      <div v-if="allSources.length === 0" class="empty-state"><Link :size="22" /><p>{{ t('emptyNodes') }}</p></div>
    </section>

    <section v-if="allSources.some(item => item.kind === 'subscription')" class="runtime-section" aria-labelledby="runtime-nodes-heading">
      <header class="nodes-section-heading">
        <div><h2 id="runtime-nodes-heading">{{ t('subscriptionNodes') }}</h2><span>{{ runtimeNodes.length }}</span></div>
      </header>
      <div v-if="subscriptionGroups.length" class="subscription-groups">
        <section v-for="group in subscriptionGroups" :key="group.name" class="subscription-group" :class="{ collapsed: isSubscriptionCollapsed(group.name) }" :aria-label="group.name">
          <header class="subscription-group-heading">
            <button class="subscription-group-toggle" type="button" :aria-expanded="!isSubscriptionCollapsed(group.name)" :aria-label="group.name" @click="toggleSubscription(group.name)">
              <ChevronRight v-if="isSubscriptionCollapsed(group.name)" :size="17" /><ChevronDown v-else :size="17" />
              <RadioTower :size="17" /><strong>{{ group.name }}</strong><span>{{ group.nodes.length }}</span>
            </button>
            <button v-if="group.source" class="icon-button" type="button" :title="t('refreshSubscription')" :aria-label="`${t('refreshSubscription')} ${group.source.name}`" :disabled="busy" @click="refreshSubscription(group.source.name)"><RefreshCw :size="16" :class="{ spin: busy }" /></button>
          </header>
          <div v-if="!isSubscriptionCollapsed(group.name) && group.nodes.length" class="runtime-node-list">
            <article v-for="item in group.nodes" :key="`${item.subscription}:${item.name}`" class="runtime-node-row horizontal-row">
              <span class="source-icon"><Waypoints :size="17" /></span>
              <div class="source-identity"><strong>{{ item.name }}</strong><span>{{ item.protocol }}</span></div>
              <span class="latency-tag" :class="`latency-${resultFor(item.name).status}`" :title="resultTitle(item.name)">
                <RefreshCw v-if="resultFor(item.name).status === 'testing'" :size="14" class="spin" />
                <template v-else-if="resultFor(item.name).status === 'ok'">{{ resultFor(item.name).delay }} ms</template>
                <template v-else-if="resultFor(item.name).status === 'error'">{{ t('latencyFailed') }}</template>
                <template v-else>—</template>
              </span>
              <div class="row-actions"><button class="icon-button" type="button" :title="t('checkLatency')" :aria-label="`${t('checkLatency')} ${item.name}`" :disabled="checkingAll || resultFor(item.name).status === 'testing'" @click="checkNode(item.name)"><Gauge :size="16" /></button></div>
            </article>
          </div>
          <div v-else-if="!isSubscriptionCollapsed(group.name)" class="empty-state compact-empty"><RadioTower :size="19" /><p>{{ state?.catalog?.runtimeConfigured ? (state?.running ? t('runtimeWaiting') : t('runtimeUnavailable')) : t('runtimeApiDisabled') }}</p></div>
        </section>
      </div>
      <div v-else class="empty-state"><RadioTower :size="22" /><p>{{ state?.catalog?.runtimeAvailable ? t('emptyNodes') : (state?.catalog?.runtimeConfigured ? (state?.running ? t('runtimeWaiting') : t('runtimeUnavailable')) : t('runtimeApiDisabled')) }}</p></div>
    </section>
  </div>
</template>
