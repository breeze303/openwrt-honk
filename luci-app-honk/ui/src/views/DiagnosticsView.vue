<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { Activity, CheckCircle2, Database, FileCheck2, FileWarning, RefreshCw, Wrench } from '@lucide/vue'
import { api } from '../api'
import { t } from '../i18n'
import type { DiagnosticsResponse, GeoAssetDiagnostic, RuntimeFileDiagnostic } from '../types'

const emit = defineEmits<{ error: [message: string] }>()
const data = ref<DiagnosticsResponse | null>(null)
const loading = ref(false)

async function load() {
  loading.value = true
  try {
    const next = await api.diagnostics()
    data.value = next
  } catch (reason) { emit('error', (reason as Error).message) }
  finally { loading.value = false }
}

function assetStatus(asset: GeoAssetDiagnostic | undefined) {
  return asset?.ok === true ? t('healthy') : t('attention')
}

function statusClass(asset: GeoAssetDiagnostic | undefined) {
  return asset?.ok === true ? 'ok' : 'warn'
}

const fileItems = computed(() => {
  const files = data.value?.files
  if (!files) return []
  return [
    ['core', t('runtimeCore')], ['tool', t('runtimeTool')], ['init', t('runtimeInit')],
    ['config', t('runtimeConfig')], ['defaultConfig', t('runtimeDefaultConfig')], ['backup', t('runtimeBackup')],
    ['launcher', t('runtimeLauncher')], ['interfaceDiscovery', t('runtimeInterfaceDiscovery')],
    ['quickWorker', t('runtimeQuickWorker')], ['geosite', t('geosite')], ['geoip', t('geoip')],
  ].map(([key, label]) => ({ key, label, item: files[key as keyof typeof files] as RuntimeFileDiagnostic }))
})

onMounted(load)
</script>

<template>
  <div class="page diagnostics-page">
    <header class="page-heading">
      <div><span class="eyebrow">{{ t('diagnostics') }}</span><h1>{{ t('runtimeHealth') }}</h1></div>
      <button class="icon-button" :title="t('refresh')" :aria-label="t('refresh')" :disabled="loading" @click="load"><RefreshCw :size="18" :class="{ spin: loading }" /></button>
    </header>

    <div class="diagnostic-grid">
      <article class="diagnostic-item"><Activity :size="20" /><div><span>{{ t('serviceState') }}</span><strong>{{ data?.service.running ? t('running') : t('stopped') }}</strong></div><i :class="data?.service.running ? 'ok' : 'warn'" /></article>
      <article class="diagnostic-item"><FileCheck2 :size="20" /><div><span>{{ t('configState') }}</span><strong>{{ data?.config.valid ? t('healthy') : t('attention') }}</strong><small>{{ data?.config.bytes || 0 }} {{ t('bytes') }}</small></div><i :class="data?.config.valid ? 'ok' : 'warn'" /></article>
      <article class="diagnostic-item"><Database :size="20" /><div><span>{{ t('geoState') }}</span><strong>{{ data?.geo.valid ? t('healthy') : t('attention') }}</strong><small>{{ data?.geo.detail.provider || '—' }}</small></div><i :class="data?.geo.valid ? 'ok' : 'warn'" /></article>
      <article class="diagnostic-item"><Wrench :size="20" /><div><span>{{ t('runtimeFiles') }}</span><strong>{{ data?.files.valid ? t('healthy') : t('attention') }}</strong><small>{{ fileItems.filter(file => file.item?.ok).length }}/{{ fileItems.length }}</small></div><i :class="data?.files.valid ? 'ok' : 'warn'" /></article>
    </div>

    <section class="geo-panel tool-panel">
      <header class="section-heading"><div><h2>{{ t('geoManagement') }}</h2><p>{{ t('geoManagementHint') }}</p></div></header>
      <div class="geo-asset-grid">
        <article v-for="kind in ['geosite', 'geoip']" :key="kind" class="geo-asset-card">
          <header><div><Database :size="18" /><strong>{{ kind === 'geosite' ? t('geosite') : t('geoip') }}</strong></div><span :class="['status-tag', statusClass(data?.geo.detail.assets[kind as 'geosite' | 'geoip'])]">{{ assetStatus(data?.geo.detail.assets[kind as 'geosite' | 'geoip']) }}</span></header>
          <dl><dt>{{ t('geoPackage') }}</dt><dd><code>{{ data?.geo.detail.assets[kind as 'geosite' | 'geoip']?.package || '—' }}</code></dd><dt>{{ t('path') }}</dt><dd><code>{{ data?.geo.detail.assets[kind as 'geosite' | 'geoip']?.path || '—' }}</code></dd><dt>{{ t('size') }}</dt><dd>{{ data?.geo.detail.assets[kind as 'geosite' | 'geoip']?.size || 0 }} {{ t('bytes') }}</dd></dl>
        </article>
      </div>
    </section>

    <section class="runtime-files-panel tool-panel">
      <header class="section-heading"><div><h2>{{ t('runtimeFiles') }}</h2><p>{{ t('runtimeFilesHint') }}</p></div></header>
      <div class="runtime-file-list">
        <article v-for="file in fileItems" :key="file.key" class="runtime-file-row">
          <component :is="file.item?.ok ? CheckCircle2 : FileWarning" :size="18" :class="file.item?.ok ? 'icon-ok' : 'icon-warn'" />
          <div><strong>{{ file.label }}</strong><code>{{ file.item?.path || '—' }}</code><small v-if="file.item?.version">{{ file.item.version }}</small></div>
          <span>{{ file.item?.ok ? t('healthy') : (file.item?.reason || t('attention')) }}</span>
        </article>
      </div>
    </section>

    <section class="diagnostic-detail">
      <h2>{{ t('recentState') }}</h2>
      <dl><dt>stage</dt><dd>{{ data?.last.stage || '—' }}</dd><dt>{{ t('configRevision') }}</dt><dd><code>{{ data?.config.revision || '—' }}</code></dd><dt>{{ t('updated') }}</dt><dd>{{ data?.last.updatedAt || '—' }}</dd></dl>
      <p v-if="data?.config.detail && !data.config.valid" role="alert">{{ data.config.detail }}</p>
    </section>
  </div>
</template>
