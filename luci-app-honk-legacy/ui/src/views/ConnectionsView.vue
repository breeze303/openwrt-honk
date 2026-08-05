<script setup lang="ts">
import { computed, ref } from 'vue'
import { Cable, Search, Trash2, X } from '@lucide/vue'
import type { ConnectionInfo } from '../api'

const props = defineProps<{ running: boolean; connections: ConnectionInfo[] }>()
const emit = defineEmits<{ close: [id: string]; closeAll: [] }>()
const search = ref('')

const visible = computed(() => {
  const needle = search.value.trim().toLowerCase()
  if (!needle) return props.connections
  return props.connections.filter(item => [
    item.metadata.host,
    item.metadata.destinationIP,
    item.metadata.sourceIP,
    item.rule,
    item.rulePayload,
    item.chains.join(' '),
  ].join(' ').toLowerCase().includes(needle))
})

function formatBytes(value = 0) {
  if (value < 1024) return `${Math.round(value)} B`
  const units = ['KiB', 'MiB', 'GiB']
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

function closeAll() {
  if (window.confirm('关闭当前全部代理连接？')) emit('closeAll')
}
</script>

<template>
  <section class="view-stack connections-view">
    <header class="view-heading">
      <div><p class="eyebrow">实时会话</p><h1>活动连接</h1></div>
      <div class="view-tools">
        <label class="search-control"><Search :size="17" /><input v-model="search" aria-label="搜索连接" placeholder="域名、地址、规则或出口" /></label>
        <button class="danger-button" :disabled="!connections.length" @click="closeAll"><Trash2 :size="17" />关闭全部</button>
      </div>
    </header>

    <div v-if="!running" class="empty-state"><Cable :size="24" /><strong>服务未运行</strong><span>当前没有可读取的代理连接。</span></div>
    <section v-else-if="visible.length" class="connection-table surface-panel" aria-label="活动连接列表">
      <header class="connection-row connection-columns" aria-hidden="true">
        <span>目标</span><span>来源</span><span>规则 / 出口</span><span>流量</span><span>时长</span><span></span>
      </header>
      <article v-for="item in visible" :key="item.id" class="connection-row">
        <div class="connection-target"><strong>{{ item.metadata.host || item.metadata.destinationIP }}</strong><span>{{ item.metadata.destinationIP }}:{{ item.metadata.destinationPort }} · {{ item.metadata.network.toUpperCase() }}</span></div>
        <div><strong>{{ item.metadata.sourceIP }}</strong><span>{{ item.metadata.sourcePort }}</span></div>
        <div><strong>{{ item.chains.join(' → ') || '-' }}</strong><span>{{ item.rule }} {{ item.rulePayload }}</span></div>
        <div class="connection-bytes"><strong>↓ {{ formatBytes(item.download) }}</strong><span>↑ {{ formatBytes(item.upload) }}</span></div>
        <div><strong>{{ elapsed(item.start) }}</strong><span>{{ new Date(item.start).toLocaleTimeString() }}</span></div>
        <button class="icon-button" title="关闭连接" aria-label="关闭连接" @click="emit('close', item.id)"><X :size="17" /></button>
      </article>
    </section>
    <div v-else class="empty-state"><Cable :size="24" /><strong>没有活动连接</strong><span>{{ search ? '没有匹配当前筛选条件的连接。' : '新的代理连接会自动显示在这里。' }}</span></div>
  </section>
</template>
