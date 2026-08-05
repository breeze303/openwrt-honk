<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from 'vue'
import { Eraser, Pause, Play, RefreshCw, ScrollText } from '@lucide/vue'
import { api, type LogFrame } from '../api'

const props = defineProps<{ logs: LogFrame[] }>()
const systemLines = ref<string[]>([])
const clearedAt = ref(0)
const paused = ref(false)
const level = ref('info')
const stream = ref<HTMLElement | null>(null)
const loading = ref(false)

const rank: Record<string, number> = { error: 0, warn: 1, info: 2, debug: 3, trace: 4 }
const visible = computed(() => {
  const live = props.logs.slice(clearedAt.value).filter(item => (rank[item.type.toLowerCase()] ?? 2) <= rank[level.value])
  const historical = systemLines.value.map(payload => ({ type: 'info', payload }))
  return [...historical, ...live].slice(-600)
})

async function refresh() {
  loading.value = true
  try {
    const result = await api.logs()
    systemLines.value = result.lines.replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '').split('\n').filter(Boolean)
  } finally {
    loading.value = false
  }
}

function clear() {
  systemLines.value = []
  clearedAt.value = props.logs.length
}

watch(visible, () => {
  if (paused.value) return
  void nextTick(() => { if (stream.value) stream.value.scrollTop = stream.value.scrollHeight })
}, { deep: true })
onMounted(refresh)
</script>

<template>
  <section class="view-stack logs-view">
    <header class="view-heading">
      <div><p class="eyebrow">Honk 核心</p><h1>运行日志</h1></div>
      <div class="view-tools">
        <div class="segmented compact" aria-label="日志级别">
          <button v-for="item in ['error', 'warn', 'info', 'debug']" :key="item" :class="{ active: level === item }" @click="level = item">{{ item.toUpperCase() }}</button>
        </div>
        <button class="icon-button" :title="paused ? '继续滚动' : '暂停滚动'" :aria-label="paused ? '继续滚动' : '暂停滚动'" @click="paused = !paused"><Play v-if="paused" :size="17" /><Pause v-else :size="17" /></button>
        <button class="icon-button" title="刷新 Honk 日志" aria-label="刷新 Honk 日志" :disabled="loading" @click="refresh"><RefreshCw :size="17" /></button>
        <button class="icon-button" title="清空显示" aria-label="清空显示" @click="clear"><Eraser :size="17" /></button>
      </div>
    </header>

    <section class="surface-panel log-surface">
      <div v-if="visible.length" ref="stream" class="log-lines" role="log" aria-live="polite">
        <div v-for="(item, index) in visible" :key="`${index}-${item.payload}`" class="log-line" :class="`log-${item.type.toLowerCase()}`">
          <span>{{ item.type.toUpperCase() }}</span><code>{{ item.payload }}</code>
        </div>
      </div>
      <div v-else class="empty-state"><ScrollText :size="24" /><strong>暂无日志</strong><span>服务运行后的事件会显示在这里。</span></div>
    </section>
  </section>
</template>
