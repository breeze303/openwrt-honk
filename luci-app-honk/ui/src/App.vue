<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { Activity, FileCode2, Gauge, Home, Languages, Menu, Network, Power, RefreshCw, RotateCcw, ScrollText, Server, X } from '@lucide/vue'
import { api } from './api'
import { locale, t } from './i18n'
import type { StateResponse } from './types'
import AdvancedView from './views/AdvancedView.vue'
import DevicesView from './views/DevicesView.vue'
import DiagnosticsView from './views/DiagnosticsView.vue'
import HomeView from './views/HomeView.vue'
import LogsView from './views/LogsView.vue'
import NodesView from './views/NodesView.vue'

type ViewName = 'home' | 'nodes' | 'devices' | 'advanced' | 'diagnostics' | 'logs'
const validViews: ViewName[] = ['home', 'nodes', 'devices', 'advanced', 'diagnostics', 'logs']
function viewFromHash(): ViewName {
  const view = window.location.hash.replace(/^#\/?/, '').split('/')[0] as ViewName
  return validViews.includes(view) ? view : 'home'
}

const initial = viewFromHash()
const active = ref<ViewName>(validViews.includes(initial) ? initial : 'home')
const state = ref<StateResponse | null>(null)
const loading = ref(false)
const serviceBusy = ref(false)
const error = ref('')
const notice = ref('')
const moreOpen = ref(false)
let refreshTimer: number | undefined

const navigation = computed(() => [
  { id: 'home' as const, label: t('home'), icon: Home },
  { id: 'nodes' as const, label: t('nodes'), icon: Server },
  { id: 'devices' as const, label: t('devices'), icon: Network },
  { id: 'advanced' as const, label: t('advanced'), icon: FileCode2 },
  { id: 'diagnostics' as const, label: t('diagnostics'), icon: Activity },
  { id: 'logs' as const, label: t('logs'), icon: ScrollText },
])
function navigate(view: ViewName) {
  active.value = view
  moreOpen.value = false
  window.location.hash = view === 'advanced' ? '/advanced/global' : `/${view}`
}

function hashChanged() {
  active.value = viewFromHash()
}

function showNotice(message: string) {
  notice.value = message
  window.setTimeout(() => { if (notice.value === message) notice.value = '' }, 4000)
}

async function refresh() {
  if (loading.value) return
  loading.value = true
  error.value = ''
  try { state.value = await api.state() }
  catch (reason) { error.value = (reason as Error).message }
  finally { loading.value = false }
}

async function service(action: 'start' | 'stop' | 'restart') {
  serviceBusy.value = true
  error.value = ''
  try {
    await api.service(action)
    showNotice(t('updated'))
    await refresh()
  } catch (reason) { error.value = (reason as Error).message }
  finally { serviceBusy.value = false }
}

onMounted(() => {
  window.addEventListener('hashchange', hashChanged)
  void refresh()
  refreshTimer = window.setInterval(() => { void refresh() }, 5000)
})
onBeforeUnmount(() => {
  window.removeEventListener('hashchange', hashChanged)
  if (refreshTimer !== undefined) window.clearInterval(refreshTimer)
})
</script>

<template>
  <div class="app-shell">
    <aside class="sidebar">
      <div class="brand"><span><Network :size="18" /></span><div><strong>OpenWrt</strong><small>{{ t('proxyService') }}</small></div></div>
      <nav :aria-label="t('menu')">
        <button v-for="item in navigation" :key="item.id" :class="{ active: active === item.id }" @click="navigate(item.id)"><component :is="item.icon" :size="18" /><span>{{ item.label }}</span></button>
      </nav>
      <div class="sidebar-footer"><span class="status-dot" :class="{ online: state?.running }" /><span>{{ state?.running ? t('running') : t('stopped') }}</span></div>
    </aside>

    <div class="workspace">
      <header class="topbar">
        <div class="runtime-summary">
          <span class="status-dot" :class="{ online: state?.running }" />
          <div><strong>{{ state?.running ? t('running') : t('stopped') }}</strong><small v-if="state?.mode">{{ state.mode }}</small></div>
        </div>
        <div class="top-actions">
          <button class="icon-button" :title="locale === 'zh' ? 'English' : '中文'" :aria-label="locale === 'zh' ? 'English' : '中文'" @click="locale = locale === 'zh' ? 'en' : 'zh'"><Languages :size="18" /></button>
          <button class="icon-button" :title="t('refresh')" :aria-label="t('refresh')" :disabled="loading" @click="refresh"><RefreshCw :size="18" :class="{ spin: loading }" /></button>
          <button v-if="state?.running" class="icon-button" :title="t('restart')" :aria-label="t('restart')" :disabled="serviceBusy" @click="service('restart')"><RotateCcw :size="18" /></button>
          <button class="service-button" :class="state?.running ? 'stop' : 'start'" :disabled="serviceBusy" @click="service(state?.running ? 'stop' : 'start')"><Power :size="17" /><span>{{ state?.running ? t('stop') : t('start') }}</span></button>
        </div>
      </header>

      <div v-if="error" class="global-alert" role="alert"><span>{{ error }}</span><button class="icon-button" :title="t('close')" :aria-label="t('close')" @click="error = ''"><X :size="17" /></button></div>
      <div v-if="notice" class="global-notice" role="status">{{ notice }}</div>

      <main class="content" :aria-busy="loading">
        <HomeView v-if="active === 'home'" :state="state" :loading="loading" @changed="refresh" @notice="showNotice" @error="message => error = message" />
        <NodesView v-else-if="active === 'nodes'" :state="state" @changed="refresh" @notice="showNotice" @error="message => error = message" />
        <DevicesView v-else-if="active === 'devices'" :state="state" @changed="refresh" @notice="showNotice" @error="message => error = message" />
        <AdvancedView v-else-if="active === 'advanced'" @changed="refresh" @notice="showNotice" @error="message => error = message" />
        <DiagnosticsView v-else-if="active === 'diagnostics'" @changed="refresh" @notice="showNotice" @error="message => error = message" />
        <LogsView v-else @error="message => error = message" />
        <div v-if="loading && !state" class="initial-loading"><Gauge :size="22" class="spin" /><span>{{ t('loading') }}</span></div>
      </main>
    </div>

    <nav class="mobile-nav" :aria-label="t('menu')">
      <button v-for="item in navigation.slice(0, 4)" :key="item.id" :class="{ active: active === item.id }" @click="navigate(item.id)"><component :is="item.icon" :size="19" /><span>{{ item.label }}</span></button>
      <button :class="{ active: active === 'diagnostics' || active === 'logs' }" @click="moreOpen = !moreOpen"><Menu :size="19" /><span>{{ t('more') }}</span></button>
    </nav>
    <div v-if="moreOpen" class="mobile-more" role="dialog" :aria-label="t('more')">
      <button @click="navigate('diagnostics')"><Activity :size="18" />{{ t('diagnostics') }}</button>
      <button @click="navigate('logs')"><ScrollText :size="18" />{{ t('logs') }}</button>
    </div>
  </div>
</template>
