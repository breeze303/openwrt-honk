<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { RefreshCw, ScrollText } from '@lucide/vue'
import { api } from '../api'
import { t } from '../i18n'

const emit = defineEmits<{ error: [message: string] }>()
const lines = ref('')
const loading = ref(false)

async function load() {
  loading.value = true
  try { lines.value = (await api.logs()).lines }
  catch (reason) { emit('error', (reason as Error).message) }
  finally { loading.value = false }
}
onMounted(load)
</script>

<template>
  <div class="page logs-page">
    <header class="page-heading"><button class="icon-button" :title="t('refresh')" :aria-label="t('refresh')" :disabled="loading" @click="load"><RefreshCw :size="18" :class="{ spin: loading }" /></button></header>
    <pre v-if="lines" class="log-output">{{ lines }}</pre>
    <div v-else class="empty-state log-empty"><ScrollText :size="24" /><p>{{ t('logEmpty') }}</p></div>
  </div>
</template>
