<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { Laptop, Plus, Save, Trash2 } from '@lucide/vue'
import { api } from '../api'
import { t } from '../i18n'
import type { DeviceRule, ModeInput, StateResponse } from '../types'

const props = defineProps<{ state: StateResponse | null }>()
const emit = defineEmits<{ changed: []; notice: [message: string]; error: [message: string] }>()
const rules = ref<DeviceRule[]>([])
const kind = ref<'ip' | 'mac'>('ip')
const value = ref('')
const outbound = ref<'direct' | 'proxy'>('proxy')
const busy = ref(false)

watch(() => props.state?.deviceRules, next => {
  rules.value = (Array.isArray(next) ? next : []).map(item => ({ ...item }))
}, { immediate: true })
const selectedSource = computed(() => {
  const node = (Array.isArray(props.state?.selected?.nodes) ? props.state.selected.nodes[0] : undefined)
    || (Array.isArray(props.state?.catalog?.nodes) ? props.state.catalog.nodes[0]?.name : undefined)
  if (node) return { kind: 'node', name: node }
  const subscription = (Array.isArray(props.state?.selected?.subscriptions) ? props.state.selected.subscriptions[0] : undefined)
    || (Array.isArray(props.state?.catalog?.subscriptions) ? props.state.catalog.subscriptions.find(item => item.enabled !== false)?.name : undefined)
  return subscription ? { kind: 'subscription', name: subscription } : null
})

function addRule() {
  if (!value.value.trim()) return
  rules.value.push({ kind: kind.value, value: value.value.trim(), outbound: outbound.value })
  value.value = ''
}

async function save() {
  if (!props.state?.mode || !selectedSource.value) { emit('error', t('sourceRequired')); return }
  const input: ModeInput = {
    mode: props.state.mode,
    nodeNames: selectedSource.value.kind === 'node' ? [selectedSource.value.name] : [],
    subscriptionNames: selectedSource.value.kind === 'subscription' ? [selectedSource.value.name] : [],
    deviceRules: rules.value,
    expectedRevision: props.state.revision,
    takeover: false,
  }
  busy.value = true
  try {
    await api.apply(input)
    emit('notice', t('applySuccess'))
    emit('changed')
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="page">
    <header class="page-heading"><div><p>{{ t('deviceHint') }}</p></div></header>
    <section class="tool-panel rule-builder">
      <div class="field-row">
        <label><span>{{ t('type') }}</span><select v-model="kind"><option value="ip">IP / CIDR</option><option value="mac">MAC</option></select></label>
        <label class="grow"><span>{{ t('address') }}</span><input v-model="value" :placeholder="kind === 'ip' ? '192.168.1.20 / 192.168.1.0/24' : '00:11:22:33:44:55'" @keyup.enter="addRule"></label>
        <label><span>{{ t('outbound') }}</span><select v-model="outbound"><option value="proxy">{{ t('proxy') }}</option><option value="direct">{{ t('direct') }}</option></select></label>
        <button class="icon-command" :title="t('add')" :aria-label="t('add')" :disabled="!value.trim()" @click="addRule"><Plus :size="19" /></button>
      </div>
    </section>
    <section class="rule-list">
      <article v-for="(rule, index) in rules" :key="`${rule.kind}:${rule.value}`" class="rule-row">
        <Laptop :size="18" />
        <code>{{ rule.value }}</code>
        <span>{{ rule.kind.toUpperCase() }}</span>
        <strong :class="rule.outbound">{{ rule.outbound === 'direct' ? t('direct') : t('proxy') }}</strong>
        <button class="icon-button danger" :title="t('remove')" :aria-label="t('remove')" @click="rules.splice(index, 1)"><Trash2 :size="17" /></button>
      </article>
      <div v-if="rules.length === 0" class="empty-state"><Laptop :size="22" /><p>{{ t('noRules') }}</p></div>
    </section>
    <div class="sticky-actions"><button class="primary-command" :disabled="busy || !state?.mode || !selectedSource" @click="save"><Save :size="18" />{{ t('saveRules') }}</button></div>
  </div>
</template>
