<script setup lang="ts">
import { AlertTriangle, LoaderCircle, PowerOff, RadioTower, RefreshCw } from '@lucide/vue'
import { t } from '../i18n'
import type { RuntimeDashboardResponse } from '../types'

defineProps<{
  bootstrap: RuntimeDashboardResponse | null
  loading: boolean
  preparing: boolean
  error: string
}>()
defineEmits<{ prepare: []; retry: [] }>()
</script>

<template>
  <section v-if="loading && !bootstrap" class="runtime-gate" aria-live="polite">
    <LoaderCircle :size="22" class="spin" />
    <div><strong>{{ t('loadingRuntime') }}</strong></div>
  </section>
  <section v-else-if="bootstrap && !bootstrap.ready" class="runtime-gate runtime-setup" role="status">
    <RadioTower :size="23" />
    <div><strong>{{ t('runtimeMonitoringDisabled') }}</strong><span>{{ t('runtimeMonitoringDisabledHint') }}</span></div>
    <button class="primary-command compact-command" :disabled="preparing" @click="$emit('prepare')"><LoaderCircle v-if="preparing" :size="15" class="spin" /><RadioTower v-else :size="15" />{{ preparing ? t('preparingRuntime') : t('enableRuntimeMonitoring') }}</button>
  </section>
  <section v-else-if="bootstrap?.ready && !bootstrap.running" class="runtime-gate" role="status">
    <PowerOff :size="23" />
    <div><strong>{{ t('runtimeServiceStopped') }}</strong><span>{{ t('runtimeServiceStoppedHint') }}</span></div>
  </section>
  <section v-else-if="!bootstrap && error" class="runtime-gate runtime-error" role="alert">
    <AlertTriangle :size="22" />
    <div><strong>{{ t('runtimeConnectionFailed') }}</strong><span>{{ error }}</span></div>
    <button class="secondary-button compact-command" @click="$emit('retry')"><RefreshCw :size="15" />{{ t('retry') }}</button>
  </section>
  <div v-else-if="error" class="runtime-inline-error" role="alert"><AlertTriangle :size="17" /><span>{{ error }}</span><button class="icon-button" :title="t('retry')" :aria-label="t('retry')" @click="$emit('retry')"><RefreshCw :size="15" /></button></div>
</template>
