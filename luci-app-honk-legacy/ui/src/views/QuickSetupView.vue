<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { AlertTriangle, Check, CircleHelp, Eye, FileCheck2, RefreshCw, ShieldCheck } from '@lucide/vue'
import { api, type QuickPreview, type QuickState } from '../api'
import { quickCopy as copy } from '../i18n'

const state = ref<QuickState | null>(null)
const loading = ref(true)
const busy = ref(false)
const error = ref('')
const notice = ref('')
const preset = ref('direct')
const lanDevice = ref('')
const wanDevice = ref('')
const selectedSubscriptions = ref<string[]>([])
const replaceAdvanced = ref(false)
const preview = ref<QuickPreview | null>(null)

const geoBlocked = computed(() => state.value?.geo?.ok !== true)
const selectedPreset = computed(() => state.value?.presets.find(item => item.id === preset.value))
const interfaces = computed(() => state.value?.discovery.interfaces.filter(item => item.safe && item.l3Device) || [])
const canPreview = computed(() => Boolean(lanDevice.value && wanDevice.value && (preset.value === 'direct' || selectedSubscriptions.value.length) && (!selectedPreset.value?.requiresGeo || !geoBlocked.value)))

function applyRecommendations(next: QuickState) {
  lanDevice.value = lanDevice.value || next.discovery.recommended?.lan || ''
  wanDevice.value = wanDevice.value || next.discovery.recommended?.wan || ''
}

async function load() {
  loading.value = true
  error.value = ''
  try {
    state.value = await api.quickState()
    applyRecommendations(state.value)
  } catch (reason) {
    error.value = reason instanceof Error ? reason.message : String(reason)
  } finally {
    loading.value = false
  }
}

function toggleSubscription(name: string) {
  selectedSubscriptions.value = selectedSubscriptions.value.includes(name)
    ? selectedSubscriptions.value.filter(item => item !== name)
    : [...selectedSubscriptions.value, name]
}

async function makePreview() {
  if (!state.value || !canPreview.value) return
  busy.value = true
  error.value = ''
  preview.value = null
  try {
    preview.value = await api.quickPreview({
      preset: preset.value,
      lanDevice: lanDevice.value,
      wanDevice: wanDevice.value,
      subscriptionNames: selectedSubscriptions.value,
      expectedRevision: state.value.revision,
      replaceAdvanced: replaceAdvanced.value,
    })
  } catch (reason) {
    error.value = reason instanceof Error ? reason.message : String(reason)
  } finally {
    busy.value = false
  }
}

async function applyPreview() {
  if (!state.value || !preview.value) return
  busy.value = true
  error.value = ''
  try {
    await api.quickApply(preview.value.previewNonce, state.value.revision)
    notice.value = copy.saved
    preview.value = null
    await load()
  } catch (reason) {
    error.value = reason instanceof Error ? reason.message : String(reason)
  } finally {
    busy.value = false
  }
}

onMounted(() => { void load() })
</script>

<template>
  <section class="view-stack quick-setup-view">
    <header class="view-heading">
      <div>
        <p class="eyebrow">Honk</p>
        <h1>{{ copy.title }}</h1>
        <span class="page-subtitle">{{ state?.running ? copy.running : copy.stopped }} · {{ state?.revision?.slice(0, 12) || copy.loading }}</span>
      </div>
      <div class="view-tools">
        <button class="icon-button" :title="copy.refresh" :aria-label="copy.refresh" :disabled="loading || busy" @click="load"><RefreshCw :size="17" /></button>
      </div>
    </header>

    <p v-if="error" class="inline-error" role="alert"><AlertTriangle :size="17" />{{ error }}</p>
    <p v-if="notice" class="inline-success" role="status"><Check :size="17" />{{ notice }}</p>

    <section class="surface-panel quick-status-panel">
      <header class="panel-heading"><div><p class="kicker">Assets</p><h2>{{ copy.assets }}</h2></div><ShieldCheck :size="20" /></header>
      <div class="quick-status-grid">
        <div><span>{{ copy.diskProvider }}</span><strong :class="{ 'quick-bad': geoBlocked }">{{ state?.geo?.diskStatus || 'MISSING' }}</strong></div>
        <div><span>{{ copy.geoPackages }}</span><strong>v2ray-geosite · v2ray-geoip</strong></div>
        <div><span>{{ copy.path }}</span><code>{{ state?.geo?.configuredPath || '/usr/share/v2ray' }}</code></div>
      </div>
      <div v-if="geoBlocked" class="quick-block-row">
        <AlertTriangle :size="17" />
        <span>{{ copy.geoBlocked }}</span>
      </div>
    </section>

    <section class="quick-setup-grid">
      <section class="surface-panel quick-form-panel">
        <header class="panel-heading"><div><p class="kicker">Workflow</p><h2>{{ copy.workflow }}</h2></div><FileCheck2 :size="20" /></header>
        <div class="quick-form-body">
          <label><span>{{ copy.preset }}</span><select v-model="preset"><option value="direct" :disabled="geoBlocked">{{ copy.direct }}</option><option value="gfwlist" :disabled="geoBlocked">{{ copy.gfwlist }}</option><option value="china-direct" :disabled="geoBlocked">{{ copy.chinaDirect }}</option><option value="global" :disabled="geoBlocked">{{ copy.global }}</option></select></label>
          <label><span>{{ copy.lan }}</span><select v-model="lanDevice"><option value="" disabled>{{ copy.chooseDevice }}</option><option v-for="item in interfaces" :key="`lan-${item.l3Device}`" :value="item.l3Device">{{ item.l3Device }} · {{ item.logicalName }}</option></select></label>
          <label><span>{{ copy.wan }}</span><select v-model="wanDevice"><option value="" disabled>{{ copy.chooseDevice }}</option><option v-for="item in interfaces" :key="`wan-${item.l3Device}`" :value="item.l3Device">{{ item.l3Device }} · {{ item.logicalName }}</option></select></label>
          <fieldset v-if="state?.subscriptions.length && preset !== 'direct'" class="quick-subscriptions"><legend>{{ copy.subscriptions }}</legend><label v-for="item in state.subscriptions" :key="item.name" class="quick-check"><input type="checkbox" :checked="selectedSubscriptions.includes(item.name)" @change="toggleSubscription(item.name)" /><span>{{ item.name }}</span></label></fieldset>
          <label v-if="state?.advancedOwned" class="quick-check quick-replace"><input v-model="replaceAdvanced" type="checkbox" /><span>{{ copy.takeOver }}</span></label>
          <button class="primary-button quick-preview-button" :disabled="busy || loading || !canPreview" @click="makePreview"><Eye :size="17" />{{ copy.preview }}</button>
        </div>
      </section>

      <section class="surface-panel quick-review-panel">
        <header class="panel-heading"><div><p class="kicker">Review</p><h2>{{ copy.review }}</h2></div><span v-if="preview" class="count-badge">{{ preview.candidateSha256.slice(0, 12) }}</span></header>
        <div v-if="preview" class="quick-review-body">
          <dl><div><dt>{{ copy.presetLabel }}</dt><dd>{{ preview.projection.preset }}</dd></div><div><dt>{{ copy.dns }}</dt><dd>{{ preview.projection.dns }}</dd></div><div><dt>{{ copy.preserved }}</dt><dd>{{ preview.preservedDigest.slice(0, 12) }}</dd></div></dl>
          <pre>{{ preview.diff || copy.noDiff }}</pre>
          <div class="quick-review-actions"><button class="secondary-button" :disabled="busy" @click="preview = null">{{ copy.cancel }}</button><button class="primary-button" :disabled="busy" @click="applyPreview"><Check :size="17" />{{ copy.applyStart }}{{ state?.running ? copy.restartSuffix : copy.startSuffix }}</button></div>
        </div>
        <div v-else class="empty-state compact"><CircleHelp :size="20" /><div><strong>{{ copy.waitingPreview }}</strong><span>{{ copy.serverCandidate }}</span></div></div>
      </section>
    </section>
  </section>
</template>
