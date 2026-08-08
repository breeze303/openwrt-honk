<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { RefreshCw, ScrollText, Trash2 } from '@lucide/vue'
import { api } from '../api'
import { t } from '../i18n'

const emit = defineEmits<{ error: [message: string]; notice: [message: string] }>()
const lines = ref('')
const loading = ref(false)
const clearing = ref(false)

async function load() {
  loading.value = true
  try { lines.value = (await api.logs()).lines }
  catch (reason) { emit('error', (reason as Error).message) }
  finally { loading.value = false }
}
onMounted(load)

async function clear() {
  if (!window.confirm(t('clearLogsConfirm'))) return
  clearing.value = true
  try {
    await api.clearLogs()
    lines.value = ''
    emit('notice', t('logsCleared'))
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    clearing.value = false
  }
}
</script>

<template>
  <div class="page logs-page">
    <header class="page-heading"><div class="log-actions"><button class="icon-button danger" :title="t('clearLogs')" :aria-label="t('clearLogs')" :disabled="loading || clearing || !lines" @click="clear"><Trash2 :size="18" :class="{ spin: clearing }" /></button><button class="icon-button" :title="t('refresh')" :aria-label="t('refresh')" :disabled="loading || clearing" @click="load"><RefreshCw :size="18" :class="{ spin: loading }" /></button></div></header>
    <pre v-if="lines" class="log-output">{{ lines }}</pre>
    <div v-else class="empty-state log-empty"><ScrollText :size="24" /><p>{{ t('logEmpty') }}</p></div>
  </div>
</template>
