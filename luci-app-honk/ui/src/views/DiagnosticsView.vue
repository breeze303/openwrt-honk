<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { Activity, Database, FileCheck2, Play, Power, RefreshCw, RotateCcw, Wrench } from '@lucide/vue'
import { api } from '../api'
import { t } from '../i18n'
import type { DiagnosticsResponse } from '../types'

const emit = defineEmits<{ changed: []; notice: [message: string]; error: [message: string] }>()
const data = ref<DiagnosticsResponse | null>(null)
const loading = ref(false)
const busy = ref(false)

async function load() {
  loading.value = true
  try { data.value = await api.diagnostics() }
  catch (reason) { emit('error', (reason as Error).message) }
  finally { loading.value = false }
}

async function service(action: 'start' | 'stop' | 'restart') {
  busy.value = true
  try {
    await api.service(action)
    emit('notice', t('updated'))
    emit('changed')
    await load()
  } catch (reason) { emit('error', (reason as Error).message) }
  finally { busy.value = false }
}

const fileHealth = computed(() => !!data.value && Object.values(data.value.files).every(Boolean))
onMounted(load)
</script>

<template>
  <div class="page">
    <header class="page-heading">
      <button class="icon-button" :title="t('refresh')" :aria-label="t('refresh')" :disabled="loading" @click="load"><RefreshCw :size="18" :class="{ spin: loading }" /></button>
    </header>
    <div class="diagnostic-grid">
      <article class="diagnostic-item"><Activity :size="20" /><div><span>{{ t('serviceState') }}</span><strong>{{ data?.service.running ? t('running') : t('stopped') }}</strong></div><i :class="data?.service.running ? 'ok' : 'warn'" /></article>
      <article class="diagnostic-item"><FileCheck2 :size="20" /><div><span>{{ t('configState') }}</span><strong>{{ data?.config.valid ? t('healthy') : t('attention') }}</strong><small>{{ data?.config.bytes || 0 }} {{ t('bytes') }}</small></div><i :class="data?.config.valid ? 'ok' : 'warn'" /></article>
      <article class="diagnostic-item"><Database :size="20" /><div><span>{{ t('geoState') }}</span><strong>{{ data?.geo.valid ? t('healthy') : t('attention') }}</strong></div><i :class="data?.geo.valid ? 'ok' : 'warn'" /></article>
      <article class="diagnostic-item"><Wrench :size="20" /><div><span>{{ t('runtimeFiles') }}</span><strong>{{ fileHealth ? t('healthy') : t('attention') }}</strong></div><i :class="fileHealth ? 'ok' : 'warn'" /></article>
    </div>
    <section class="service-controls">
      <button class="secondary-button" :disabled="busy" @click="service('start')"><Play :size="17" />{{ t('start') }}</button>
      <button class="secondary-button" :disabled="busy" @click="service('restart')"><RotateCcw :size="17" />{{ t('restart') }}</button>
      <button class="danger-button" :disabled="busy" @click="service('stop')"><Power :size="17" />{{ t('stop') }}</button>
    </section>
    <section class="diagnostic-detail">
      <h2>{{ t('recentState') }}</h2>
      <dl><dt>stage</dt><dd>{{ data?.last.stage || '—' }}</dd><dt>{{ t('configRevision') }}</dt><dd><code>{{ data?.config.revision || '—' }}</code></dd><dt>{{ t('updated') }}</dt><dd>{{ data?.last.updatedAt || '—' }}</dd></dl>
      <p v-if="data?.config.detail && !data.config.valid" role="alert">{{ data.config.detail }}</p>
    </section>
  </div>
</template>
