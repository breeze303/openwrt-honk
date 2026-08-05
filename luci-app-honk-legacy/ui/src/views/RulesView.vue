<script setup lang="ts">
import { computed, ref } from 'vue'
import { ListFilter, Search } from '@lucide/vue'
import type { ClashRule } from '../api'

const props = defineProps<{ running: boolean; rules: ClashRule[] }>()
const search = ref('')
const visible = computed(() => {
  const needle = search.value.trim().toLowerCase()
  if (!needle) return props.rules
  return props.rules.filter(rule => `${rule.type || ''} ${rule.payload || ''} ${rule.proxy || ''}`.toLowerCase().includes(needle))
})
</script>

<template>
  <section class="view-stack rules-view">
    <header class="view-heading">
      <div><p class="eyebrow">生效顺序</p><h1>运行规则</h1></div>
      <label class="search-control"><Search :size="17" /><input v-model="search" aria-label="搜索运行规则" placeholder="搜索类型、内容或出口" /></label>
    </header>

    <section v-if="running && visible.length" class="surface-panel rule-runtime-list">
      <header class="runtime-rule runtime-rule-head" aria-hidden="true"><span>序号</span><span>类型</span><span>匹配内容</span><span>出口</span></header>
      <article v-for="(rule, index) in visible" :key="`${rule.type}-${rule.payload}-${index}`" class="runtime-rule">
        <span class="rule-index">{{ String(index + 1).padStart(2, '0') }}</span>
        <strong>{{ rule.type || 'MATCH' }}</strong>
        <code>{{ rule.payload || '-' }}</code>
        <span class="rule-proxy">{{ rule.proxy || 'direct' }}</span>
      </article>
    </section>
    <div v-else class="empty-state"><ListFilter :size="24" /><strong>{{ running ? '没有匹配的运行规则' : '服务未运行' }}</strong><span>{{ running ? '修改搜索条件或前往配置页面添加规则。' : '启动 Honk 后可查看解析后的生效规则。' }}</span></div>
  </section>
</template>
