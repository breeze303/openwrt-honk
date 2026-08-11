<script setup lang="ts">
import { computed, ref } from 'vue'
import { Cable, Search, Trash2, X } from '@lucide/vue'
import RuntimeGate from '../components/RuntimeGate.vue'
import { t } from '../i18n'
import type { RuntimeMonitoring } from '../composables/useRuntimeMonitoring'
import type { StateResponse } from '../types'

const props = defineProps<{ state: StateResponse | null; runtime: RuntimeMonitoring }>()
const emit = defineEmits<{ changed: []; notice: [message: string]; error: [message: string] }>()
const runtime = props.runtime
const { bootstrap, connections, loading, preparing, error, closingIds, closingAll } = runtime
const search = ref('')
const visible = computed(() => {
  const needle = search.value.trim().toLowerCase()
  if (!needle) return connections.value.connections
  return connections.value.connections.filter(item => [
    item.metadata.host, item.metadata.destinationIP, item.metadata.sourceIP, item.metadata.process,
    item.metadata.processPath, item.rule, item.rulePayload, item.chains.join(' '),
  ].join(' ').toLowerCase().includes(needle))
})

function formatBytes(value = 0) {
  if (value < 1024) return `${Math.round(value)} B`
  const units = ['KiB', 'MiB', 'GiB', 'TiB']
  let current = value
  let index = -1
  do { current /= 1024; index += 1 } while (current >= 1024 && index < units.length - 1)
  return `${current >= 10 ? current.toFixed(0) : current.toFixed(1)} ${units[index]}`
}

function elapsed(start: string) {
  const seconds = Math.max(0, Math.round((Date.now() - new Date(start).getTime()) / 1000))
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`
}

async function prepareRuntime() {
  if (!props.state?.revision) return
  try {
    await runtime.prepare(props.state.revision)
    emit('changed')
    emit('notice', t('runtimeMonitoringEnabled'))
  } catch (reason) { emit('error', (reason as Error).message) }
}

async function closeConnection(id: string) {
  try { await runtime.closeConnection(id) }
  catch (reason) { emit('error', (reason as Error).message) }
}

async function closeAll() {
  if (!window.confirm(t('closeAllConnectionsConfirm'))) return
  try { await runtime.closeAllConnections() }
  catch (reason) { emit('error', (reason as Error).message) }
}
</script>

<template>
  <div class="page connections-page">
    <header class="page-heading connections-heading">
      <div><span class="eyebrow">{{ t('connectionsLive') }}</span><h1>{{ t('activeConnections') }}</h1></div>
      <div v-if="bootstrap?.ready && bootstrap.running" class="connection-tools"><label class="runtime-search"><Search :size="16" /><input v-model="search" :aria-label="t('searchConnections')" :placeholder="t('searchConnectionsPlaceholder')" /></label><button class="danger-button compact-command" :disabled="!connections.connections.length || closingAll" @click="closeAll"><Trash2 :size="15" />{{ t('closeAllConnections') }}</button></div>
    </header>
    <RuntimeGate :bootstrap="bootstrap" :loading="loading" :preparing="preparing" :error="error" @prepare="prepareRuntime" @retry="runtime.retry" />

    <template v-if="bootstrap?.ready && bootstrap.running">
      <div class="connection-summary"><strong>{{ visible.length }}</strong><span>/ {{ connections.connections.length }} {{ t('connectionsUnit') }}</span></div>
      <section v-if="visible.length" class="connection-table" :aria-label="t('activeConnections')">
        <header class="connection-row connection-columns" aria-hidden="true"><span>{{ t('target') }}</span><span>{{ t('connectionSource') }}</span><span>{{ t('ruleAndOutbound') }}</span><span>{{ t('trafficColumn') }}</span><span>{{ t('duration') }}</span><span></span></header>
        <article v-for="item in visible" :key="item.id" class="connection-row">
          <div class="connection-target"><strong>{{ item.metadata.host || item.metadata.destinationIP }}</strong><span>{{ item.metadata.destinationIP }}:{{ item.metadata.destinationPort }} · {{ item.metadata.network.toUpperCase() }}</span></div>
          <div class="connection-process" :title="item.metadata.processPath || ''"><strong>{{ item.metadata.process || item.metadata.sourceIP }}</strong><span>{{ item.metadata.sourceIP }}:{{ item.metadata.sourcePort }}<template v-if="item.metadata.processPath"> · {{ item.metadata.processPath }}</template></span></div>
          <div><strong>{{ item.chains.join(' → ') || t('routeDefault') }}</strong><span>{{ item.rule }} {{ item.rulePayload }}</span></div>
          <div class="connection-bytes"><strong>↓ {{ formatBytes(item.download) }}</strong><span>↑ {{ formatBytes(item.upload) }}</span></div>
          <div><strong>{{ elapsed(item.start) }}</strong><span>{{ new Date(item.start).toLocaleTimeString() }}</span></div>
          <button class="icon-button" :title="t('closeConnection')" :aria-label="t('closeConnection')" :disabled="closingIds.includes(item.id)" @click="closeConnection(item.id)"><X :size="16" /></button>
        </article>
      </section>
      <div v-else class="empty-state"><Cable :size="24" /><strong>{{ search ? t('noMatchingConnections') : t('noActiveConnections') }}</strong><p>{{ search ? t('adjustConnectionSearch') : t('connectionsAppearHere') }}</p></div>
    </template>
  </div>
</template>
