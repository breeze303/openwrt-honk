<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { AlertTriangle, Check, CheckCircle2, ChevronRight, Gauge, RotateCcw, Server, ShieldCheck, X } from '@lucide/vue'
import { api } from '../api'
import { t } from '../i18n'
import type { ConnectivityCheck, ModeInput, ModeName, PreviewResponse, StateResponse } from '../types'

const props = defineProps<{ state: StateResponse | null; loading: boolean }>()
const emit = defineEmits<{ changed: []; notice: [message: string]; error: [message: string] }>()

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

const sources = computed(() => [
  ...(Array.isArray(props.state?.catalog?.nodes) ? props.state.catalog.nodes : []).map(item => ({ ...item, value: `node:${item.name}` })),
  ...(Array.isArray(props.state?.catalog?.subscriptions) ? props.state.catalog.subscriptions : []).filter(item => item.enabled !== false).map(item => ({ ...item, value: `subscription:${item.name}` })),
  ...(Array.isArray(props.state?.catalog?.subscriptionNodes) ? props.state.catalog.subscriptionNodes : []).map(item => ({ ...item, value: `runtime:${item.name}` })),
])

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
</script>

<template>
  <div class="page home-page">
    <header class="page-heading home-heading">
      <div class="service-pill" :class="state?.running ? 'ok' : 'muted'" role="status">
        <span class="status-dot" />
        <strong>{{ state?.running ? t('running') : t('stopped') }}</strong>
      </div>
    </header>

    <section class="mode-section" aria-labelledby="mode-heading">
      <div class="section-label">
        <div><span>01</span><h2 id="mode-heading">{{ t('currentMode') }}</h2></div>
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
        <div><span>02</span><h2 id="source-heading">{{ t('currentSource') }}</h2></div>
      </div>
      <label class="source-select">
        <Server :size="18" />
        <select v-model="selectedSource" :disabled="sources.length === 0" @change="markSourceDirty">
          <option value="" disabled>{{ t('sourceRequired') }}</option>
          <option v-for="item in sources" :key="item.value" :value="item.value">{{ item.name }} · {{ item.protocol }}{{ 'subscription' in item ? ` · ${item.subscription === 'runtime' ? t('subscriptionNodes') : item.subscription}` : '' }}</option>
        </select>
        <ChevronRight :size="18" />
      </label>
      <p v-if="sources.length === 0" class="inline-warning"><AlertTriangle :size="16" />{{ t('emptyNodes') }}</p>
      <p v-else-if="state?.catalog?.subscriptions?.length && !state?.catalog?.runtimeAvailable" class="inline-warning"><AlertTriangle :size="16" />{{ state?.catalog?.runtimeConfigured ? (state?.running ? t('runtimeWaiting') : t('runtimeUnavailable')) : t('runtimeApiDisabled') }}</p>
    </section>

    <section class="connectivity-section" aria-labelledby="connectivity-heading" aria-live="polite">
      <div class="connectivity-head">
        <div>
          <div class="section-label compact">
            <div><span>03</span><h2 id="connectivity-heading">{{ t('connectivity') }}</h2></div>
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

    <section class="apply-band">
      <div>
        <span>{{ t('configRevision') }}</span>
        <code>{{ state?.revision?.slice(0, 12) || '—' }}</code>
      </div>
      <button class="primary-command" :disabled="busy || loading || !selectedSource" @click="openPreview">
        <ShieldCheck :size="18" />{{ busy ? t('applying') : t('apply') }}
      </button>
    </section>

    <section class="recent-section" aria-labelledby="recent-heading">
      <div class="section-label compact">
        <div><span>04</span><h2 id="recent-heading">{{ t('recentState') }}</h2></div>
      </div>
      <div class="recent-row" :class="{ warning: state?.rollback }">
        <RotateCcw v-if="state?.rollback" :size="18" />
        <CheckCircle2 v-else :size="18" />
        <div>
          <strong>{{ state?.rollback ? t('rollback') : (state?.last.stage || t('noError')) }}</strong>
          <span>{{ state?.recentError || state?.last.updatedAt || t('noError') }}</span>
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
