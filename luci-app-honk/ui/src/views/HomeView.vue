<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { AlertTriangle, Check, CheckCircle2, Gauge, ShieldCheck, X } from '@lucide/vue'
import { api } from '../api'
import { t } from '../i18n'
import type { PageAction } from '../page-actions'
import type { ConnectivityCheck, ModeInput, ModeName, PreviewResponse, StateResponse } from '../types'
import SourcePicker from '../components/SourcePicker.vue'
import type { SourcePickerGroup, SourcePickerOption } from '../components/SourcePicker.vue'

const props = defineProps<{ state: StateResponse | null; loading: boolean }>()
const emit = defineEmits<{ changed: []; notice: [message: string]; error: [message: string]; pageActions: [actions: PageAction[]] }>()

const selectedMode = ref<ModeName>('china-direct')
const selectedSource = ref('')
const preview = ref<PreviewResponse | null>(null)
const takeoverAccepted = ref(false)
const busy = ref(false)
const connectivity = ref<Partial<Record<ConnectivityCheck['id'], ConnectivityCheck>>>({})
const connectivityBusy = ref<Partial<Record<ConnectivityCheck['id'], boolean>>>({})
const sourceDirty = ref(false)
const awaitingApply = ref(false)
let syncedRevision = ''

const modes: Array<{ id: ModeName; label: () => string; description: () => string }> = [
  { id: 'china-direct', label: () => t('chinaDirect'), description: () => t('chinaDirectDesc') },
  { id: 'gfwlist', label: () => t('gfw'), description: () => t('gfwDesc') },
  { id: 'china-proxy', label: () => t('chinaProxy'), description: () => t('chinaProxyDesc') },
  { id: 'global', label: () => t('global'), description: () => t('globalDesc') },
]

const connectivityTargets: Array<Pick<ConnectivityCheck, 'id' | 'url' | 'route'>> = [
  { id: 'aliyun', url: 'https://www.aliyun.com', route: 'direct' },
  { id: 'google', url: 'https://www.google.com/generate_204', route: 'honk-proxy' },
  { id: 'github', url: 'https://github.com', route: 'honk-proxy' },
  { id: 'youtube', url: 'https://www.youtube.com', route: 'honk-proxy' },
]

const sourceGroups = computed<SourcePickerGroup[]>(() => {
  const nodes = Array.isArray(props.state?.catalog?.nodes) ? props.state.catalog.nodes : []
  const subscriptions = (Array.isArray(props.state?.catalog?.subscriptions) ? props.state.catalog.subscriptions : []).filter(item => item.enabled !== false)
  const runtimeNodes = Array.isArray(props.state?.catalog?.subscriptionNodes) ? props.state.catalog.subscriptionNodes : []
  const groups: SourcePickerGroup[] = []

  const manualOptions: SourcePickerOption[] = nodes.map(item => ({
    value: `node:${item.name}`,
    label: item.name,
    detail: item.protocol,
    kind: 'node',
    searchText: `${item.name} ${item.protocol}`.toLocaleLowerCase(),
  }))
  if (manualOptions.length) groups.push({ id: 'manual', label: t('manualNodes'), count: manualOptions.length, options: manualOptions })

  const groupedSubscriptions = new Set<string>()
  for (const subscription of subscriptions) {
    groupedSubscriptions.add(subscription.name)
    const subscriptionNodes = runtimeNodes.filter(item => item.subscription === subscription.name)
    const options: SourcePickerOption[] = [
      {
        value: `subscription:${subscription.name}`,
        label: subscription.name,
        detail: t('useSubscription'),
        kind: 'subscription',
        searchText: `${subscription.name} ${t('useSubscription')}`.toLocaleLowerCase(),
      },
      ...subscriptionNodes.map(item => ({
        value: `runtime:${item.name}`,
        label: item.name,
        detail: item.protocol,
        kind: 'runtime' as const,
        searchText: `${item.name} ${item.protocol} ${subscription.name}`.toLocaleLowerCase(),
      })),
    ]
    groups.push({ id: `subscription:${subscription.name}`, label: subscription.name, count: subscriptionNodes.length, options })
  }

  const unassigned = runtimeNodes.filter(item => !groupedSubscriptions.has(item.subscription))
  if (unassigned.length) {
    groups.push({
      id: 'runtime-unassigned',
      label: t('unassignedNodes'),
      count: unassigned.length,
      options: unassigned.map(item => ({
        value: `runtime:${item.name}`,
        label: item.name,
        detail: item.protocol,
        kind: 'runtime',
        searchText: `${item.name} ${item.protocol} ${item.subscription}`.toLocaleLowerCase(),
      })),
    })
  }

  return groups
})

const sources = computed(() => sourceGroups.value.flatMap(group => group.options))

watch(() => props.state, state => {
  if (!state) return
  const revisionChanged = syncedRevision !== state.revision
  if (revisionChanged) {
    syncedRevision = state.revision
    selectedMode.value = state.mode || 'china-direct'
  }
  const node = Array.isArray(state.selected?.nodes) ? state.selected.nodes[0] : undefined
  const subscription = Array.isArray(state.selected?.subscriptions) ? state.selected.subscriptions[0] : undefined
  const runtime = node && Array.isArray(state.catalog?.subscriptionNodes)
    ? state.catalog.subscriptionNodes.find(item => item.name === node)
    : undefined
  const current = runtime ? `runtime:${runtime.name}` : node ? `node:${node}` : subscription ? `subscription:${subscription}` : ''
  const currentIsValid = current !== '' && sources.value.some(item => item.value === current)
  const selectedIsValid = selectedSource.value !== '' && sources.value.some(item => item.value === selectedSource.value)
  if (sourceDirty.value) {
    if (!selectedIsValid) {
      selectedSource.value = currentIsValid ? current : sources.value[0]?.value || ''
      sourceDirty.value = false
      awaitingApply.value = false
    } else if (awaitingApply.value && current === selectedSource.value) {
      sourceDirty.value = false
      awaitingApply.value = false
    }
    return
  }
  if (currentIsValid) selectedSource.value = current
  else if (!selectedIsValid) selectedSource.value = sources.value[0]?.value || ''
}, { immediate: true })

function markSourceDirty() {
  sourceDirty.value = true
  awaitingApply.value = false
}

function selectSource(value: string) {
  if (value === selectedSource.value) return
  selectedSource.value = value
  markSourceDirty()
}

function modeInput(takeover = false): ModeInput {
  const [kind, ...parts] = selectedSource.value.split(':')
  let name = parts.join(':')
  return {
    mode: selectedMode.value,
    nodeNames: (kind === 'node' || kind === 'runtime') && name ? [name] : [],
    subscriptionNames: kind === 'subscription' && name ? [name] : [],
    deviceRules: Array.isArray(props.state?.deviceRules) ? props.state.deviceRules : [],
    expectedRevision: props.state?.revision || '',
    takeover,
  }
}

async function openPreview() {
  if (!selectedSource.value) { emit('error', t('sourceRequired')); return }
  busy.value = true
  takeoverAccepted.value = false
  try {
    preview.value = await api.preview(modeInput())
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    busy.value = false
  }
}

async function confirmApply() {
  if (!preview.value || (preview.value.requiresTakeover && !takeoverAccepted.value)) return
  busy.value = true
  try {
    await api.apply(modeInput(takeoverAccepted.value))
    preview.value = null
    awaitingApply.value = true
    emit('notice', t('applySuccess'))
    emit('changed')
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    busy.value = false
  }
}

function connectivityLabel(id: ConnectivityCheck['id']): string {
  if (id === 'aliyun') return t('connectivityAliyun')
  if (id === 'google') return t('connectivityGoogle')
  if (id === 'github') return t('connectivityGithub')
  return t('connectivityYoutube')
}

function connectivityRouteLabel(route: ConnectivityCheck['route']): string {
  return route === 'direct' ? t('connectivityDirect') : t('connectivityProxy')
}

async function testConnectivity(id: ConnectivityCheck['id']) {
  if (connectivityBusy.value[id] || !props.state?.running) return
  const target = connectivityTargets.find(item => item.id === id)
  if (!target) return
  connectivityBusy.value = { ...connectivityBusy.value, [id]: true }
  try {
    const response = await api.connectivity(id)
    connectivity.value = { ...connectivity.value, [id]: response.check }
  } catch (reason) {
    connectivity.value = {
      ...connectivity.value,
      [id]: { ...target, ok: false, status: 0, error: (reason as Error).message },
    }
    emit('error', (reason as Error).message)
  } finally {
    connectivityBusy.value = { ...connectivityBusy.value, [id]: false }
  }
}

function publishPageActions() {
  emit('pageActions', [{
    id: 'apply-mode',
    label: t('apply'),
    disabled: busy.value || props.loading || !selectedSource.value,
    busy: busy.value,
    run: openPreview,
  }])
}

watch([selectedSource, busy, () => props.loading, () => props.state?.revision], publishPageActions, { immediate: true })
</script>

<template>
  <div class="page home-page">
    <section class="mode-section" aria-labelledby="mode-heading">
      <div class="section-label">
        <div><h2 id="mode-heading">{{ t('currentMode') }}</h2></div>
        <strong>{{ modes.find(item => item.id === selectedMode)?.label() }}</strong>
      </div>
      <div class="mode-grid">
        <button v-for="item in modes" :key="item.id" class="mode-card" :class="{ selected: selectedMode === item.id }" :aria-pressed="selectedMode === item.id" @click="selectedMode = item.id">
          <span class="mode-check"><Check v-if="selectedMode === item.id" :size="15" /></span>
          <strong>{{ item.label() }}</strong>
          <span>{{ item.description() }}</span>
        </button>
      </div>
    </section>

    <section class="source-section" aria-labelledby="source-heading">
      <div class="section-label">
        <div><h2 id="source-heading">{{ t('currentSource') }}</h2></div>
      </div>
      <SourcePicker
        :model-value="selectedSource"
        :groups="sourceGroups"
        :disabled="sources.length === 0"
        :placeholder="t('sourceRequired')"
        :search-placeholder="t('searchNodes')"
        :empty-label="t('noMatchingNodes')"
        :ariaLabel="t('currentSource')"
        @update:model-value="selectSource"
      />
      <p v-if="sources.length === 0" class="inline-warning"><AlertTriangle :size="16" />{{ t('emptyNodes') }}</p>
      <p v-else-if="state?.catalog?.subscriptions?.length && !state?.catalog?.runtimeAvailable && !state?.catalog?.cacheAvailable" class="inline-warning"><AlertTriangle :size="16" />{{ state?.catalog?.runtimeConfigured ? (state?.running ? t('runtimeWaiting') : t('runtimeUnavailable')) : t('runtimeApiDisabled') }}</p>
    </section>

    <section class="connectivity-section" aria-labelledby="connectivity-heading" aria-live="polite">
      <div class="connectivity-head">
        <div>
          <div class="section-label compact">
            <div><h2 id="connectivity-heading">{{ t('connectivity') }}</h2></div>
          </div>
          <p class="connectivity-hint">{{ t('connectivityHint') }}</p>
        </div>
      </div>
      <div class="connectivity-results">
        <div v-for="target in connectivityTargets" :key="target.id" class="connectivity-result" :class="{ ok: connectivity[target.id]?.ok, pending: connectivityBusy[target.id] }">
          <component :is="connectivityBusy[target.id] ? Gauge : connectivity[target.id] ? (connectivity[target.id]?.ok ? CheckCircle2 : AlertTriangle) : Gauge" :size="18" :class="{ spin: connectivityBusy[target.id] }" />
          <div class="connectivity-result-label">
            <strong>{{ connectivityLabel(target.id) }}</strong>
            <small>{{ connectivityRouteLabel(target.route) }}</small>
          </div>
          <div class="connectivity-result-meta">
            <span v-if="connectivity[target.id]?.ok" class="latency-tag latency-ok">{{ connectivity[target.id]?.latency ?? '—' }} ms</span>
            <span v-else-if="connectivity[target.id]" class="latency-tag latency-error">{{ t('connectivityFailed') }}</span>
            <button class="connectivity-test-button secondary-button" type="button" :disabled="connectivityBusy[target.id] || loading || !state?.running" @click="testConnectivity(target.id)">
              <Gauge :size="15" :class="{ spin: connectivityBusy[target.id] }" />{{ connectivityBusy[target.id] ? t('testingConnectivity') : t('testConnectivity') }}
            </button>
          </div>
        </div>
      </div>
    </section>

    <div v-if="preview" class="modal-backdrop" @click.self="preview = null">
      <section class="modal" role="dialog" aria-modal="true" :aria-label="t('preview')">
        <header class="modal-heading">
          <div><p class="eyebrow">{{ t('preview') }}</p><h2>{{ modes.find(item => item.id === preview?.mode)?.label() }}</h2></div>
          <button class="icon-button" :title="t('close')" :aria-label="t('close')" @click="preview = null"><X :size="19" /></button>
        </header>
        <div v-if="preview.requiresTakeover" class="takeover-warning">
          <AlertTriangle :size="20" />
          <div><strong>{{ t('advanced') }}</strong><p>{{ t('takeover') }}</p></div>
        </div>
        <label v-if="preview.requiresTakeover" class="check-row">
          <input v-model="takeoverAccepted" type="checkbox">{{ t('acknowledge') }}
        </label>
        <div class="preview-grid">
          <section><h3>{{ t('routeImpact') }}</h3><code v-for="line in preview.routing.filter(line => line.includes('->') || line.includes('fallback'))" :key="line">{{ line.trim() }}</code></section>
          <section><h3>{{ t('dnsImpact') }}</h3><code v-for="line in preview.dns" :key="line">{{ line.trim() }}</code></section>
        </div>
        <footer class="modal-actions">
          <span>{{ t('changedLines') }}: +{{ preview.changes.additions }} / -{{ preview.changes.removals }}</span>
          <button class="secondary-button" @click="preview = null">{{ t('cancel') }}</button>
          <button class="primary-command" :disabled="busy || (preview.requiresTakeover && !takeoverAccepted)" @click="confirmApply"><ShieldCheck :size="18" />{{ t('confirmApply') }}</button>
        </footer>
      </section>
    </div>
  </div>
</template>
