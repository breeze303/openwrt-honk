<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { Activity, Cable, ChartNoAxesCombined, FileCode2, Gauge, Home, Languages, Menu, Moon, Network, Power, RefreshCw, RotateCcw, Save, ScrollText, Server, Sun, X } from '@lucide/vue'
import { api } from './api'
import { useRuntimeMonitoring } from './composables/useRuntimeMonitoring'
import { locale, t } from './i18n'
import type { PageAction } from './page-actions'
import type { StateResponse } from './types'
import AdvancedView from './views/AdvancedView.vue'
import ConnectionsView from './views/ConnectionsView.vue'
import DevicesView from './views/DevicesView.vue'
import DiagnosticsView from './views/DiagnosticsView.vue'
import HomeView from './views/HomeView.vue'
import LogsView from './views/LogsView.vue'
import NodesView from './views/NodesView.vue'
import TrafficView from './views/TrafficView.vue'

type ViewName = 'home' | 'traffic' | 'connections' | 'nodes' | 'devices' | 'advanced' | 'diagnostics' | 'logs'
const validViews: ViewName[] = ['home', 'traffic', 'connections', 'nodes', 'devices', 'advanced', 'diagnostics', 'logs']
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
const pageActions = ref<PageAction[]>([])
const pageActionMenuOpen = ref(false)
const runtime = useRuntimeMonitoring()
const storedTheme = typeof window === 'undefined' ? null : window.localStorage.getItem('honk-theme')
const followsSystemTheme = ref(storedTheme !== 'light' && storedTheme !== 'dark')
const theme = ref<'light' | 'dark'>(storedTheme === 'dark' || (storedTheme !== 'light' && window.matchMedia?.('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light')
let mediaQuery: MediaQueryList | undefined

const navigation = computed(() => [
  { id: 'home' as const, label: t('home'), icon: Home },
  { id: 'traffic' as const, label: t('traffic'), icon: ChartNoAxesCombined },
  { id: 'connections' as const, label: t('connections'), icon: Cable },
  { id: 'nodes' as const, label: t('nodes'), icon: Server },
  { id: 'devices' as const, label: t('devices'), icon: Network },
  { id: 'advanced' as const, label: t('advanced'), icon: FileCode2 },
  { id: 'diagnostics' as const, label: t('diagnostics'), icon: Activity },
  { id: 'logs' as const, label: t('logs'), icon: ScrollText },
])
const runtimePageActive = computed(() => active.value === 'traffic' || active.value === 'connections')
function navigate(view: ViewName) {
  active.value = view
  moreOpen.value = false
  pageActionMenuOpen.value = false
  window.location.hash = view === 'advanced' ? '/advanced/global' : `/${view}`
}

function hashChanged() {
  active.value = viewFromHash()
}

function showNotice(message: string) {
  notice.value = message
  window.setTimeout(() => { if (notice.value === message) notice.value = '' }, 4000)
}

function setPageActions(actions: PageAction[]) {
  pageActions.value = actions
  pageActionMenuOpen.value = false
}

const pageActionLabel = computed(() => pageActions.value.length === 1 ? pageActions.value[0].label : t('saveChanges'))
const pageActionDisabled = computed(() => pageActions.value.length === 0 || pageActions.value.every(action => action.disabled || action.busy))
const pageActionBusy = computed(() => pageActions.value.some(action => action.busy))

async function runPageAction(action: PageAction) {
  if (action.disabled || action.busy) return
  pageActionMenuOpen.value = false
  try {
    await action.run()
  } catch (reason) {
    error.value = (reason as Error).message
  }
}

function triggerPageAction() {
  if (pageActionDisabled.value) return
  if (pageActions.value.length === 1) {
    void runPageAction(pageActions.value[0])
    return
  }
  pageActionMenuOpen.value = !pageActionMenuOpen.value
}

function closePageActionMenu(event: MouseEvent) {
  const target = event.target
  if (!(target instanceof Element) || !target.closest('.page-action-control')) pageActionMenuOpen.value = false
}

function applyTheme() {
  document.documentElement.dataset.theme = theme.value
  document.documentElement.style.colorScheme = theme.value
}

function toggleTheme() {
  followsSystemTheme.value = false
  theme.value = theme.value === 'dark' ? 'light' : 'dark'
  window.localStorage.setItem('honk-theme', theme.value)
}

function handleSystemTheme(event: MediaQueryListEvent) {
  if (followsSystemTheme.value) theme.value = event.matches ? 'dark' : 'light'
}

watch(active, () => setPageActions([]))
watch([runtimePageActive, () => state.value?.revision, () => state.value?.running], ([visible, revision]) => {
  if (visible && revision) void runtime.activate(revision)
  else runtime.deactivate()
}, { immediate: true })
watch(theme, applyTheme)

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
  applyTheme()
  mediaQuery = window.matchMedia?.('(prefers-color-scheme: dark)')
  mediaQuery?.addEventListener('change', handleSystemTheme)
  document.addEventListener('click', closePageActionMenu)
  window.addEventListener('hashchange', hashChanged)
  void refresh()
})
onBeforeUnmount(() => {
  mediaQuery?.removeEventListener('change', handleSystemTheme)
  document.removeEventListener('click', closePageActionMenu)
  window.removeEventListener('hashchange', hashChanged)
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
          <button class="icon-button" :title="locale === 'zh' ? 'English' : '中文'" :aria-label="locale === 'zh' ? 'English' : '中文'" @click="locale = locale === 'zh' ? 'en' : 'zh'"><Languages :size="16" /></button>
          <button class="icon-button" :title="theme === 'dark' ? t('lightMode') : t('darkMode')" :aria-label="theme === 'dark' ? t('lightMode') : t('darkMode')" @click="toggleTheme"><Sun v-if="theme === 'dark'" :size="16" /><Moon v-else :size="16" /></button>
          <button class="icon-button" :title="t('refresh')" :aria-label="t('refresh')" :disabled="loading" @click="refresh"><RefreshCw :size="16" :class="{ spin: loading }" /></button>
          <button v-if="state?.running" class="icon-button" :title="t('restart')" :aria-label="t('restart')" :disabled="serviceBusy" @click="service('restart')"><RotateCcw :size="16" /></button>
          <div v-if="pageActions.length" class="page-action-control">
            <button class="icon-button page-save-button" :title="pageActionLabel" :aria-label="pageActionLabel" :disabled="pageActionDisabled" @click="triggerPageAction"><Save :size="16" :class="{ spin: pageActionBusy }" /></button>
            <div v-if="pageActionMenuOpen" class="page-action-menu" role="menu" :aria-label="t('saveChanges')">
              <button v-for="action in pageActions" :key="action.id" type="button" role="menuitem" :disabled="action.disabled || action.busy" @click="runPageAction(action)">{{ action.label }}</button>
            </div>
          </div>
          <button class="service-button" :class="state?.running ? 'stop' : 'start'" :disabled="serviceBusy" @click="service(state?.running ? 'stop' : 'start')"><Power :size="16" /><span>{{ state?.running ? t('stop') : t('start') }}</span></button>
        </div>
      </header>

      <div v-if="error" class="global-alert" role="alert"><span>{{ error }}</span><button class="icon-button" :title="t('close')" :aria-label="t('close')" @click="error = ''"><X :size="17" /></button></div>
      <div v-if="notice" class="global-notice" role="status">{{ notice }}</div>

      <main class="content" :aria-busy="loading">
        <HomeView v-if="active === 'home'" :state="state" :loading="loading" @changed="refresh" @notice="showNotice" @error="message => error = message" @page-actions="setPageActions" />
        <TrafficView v-else-if="active === 'traffic'" :state="state" :runtime="runtime" @changed="refresh" @notice="showNotice" @error="message => error = message" />
        <ConnectionsView v-else-if="active === 'connections'" :state="state" :runtime="runtime" @changed="refresh" @notice="showNotice" @error="message => error = message" />
        <NodesView v-else-if="active === 'nodes'" :state="state" @changed="refresh" @notice="showNotice" @error="message => error = message" @page-actions="setPageActions" />
        <DevicesView v-else-if="active === 'devices'" :state="state" @changed="refresh" @notice="showNotice" @error="message => error = message" @page-actions="setPageActions" />
        <AdvancedView v-else-if="active === 'advanced'" @changed="refresh" @notice="showNotice" @error="message => error = message" @page-actions="setPageActions" />
        <DiagnosticsView v-else-if="active === 'diagnostics'" @notice="showNotice" @error="message => error = message" @page-actions="setPageActions" />
        <LogsView v-else @error="message => error = message" @notice="showNotice" />
        <div v-if="loading && !state" class="initial-loading"><Gauge :size="22" class="spin" /><span>{{ t('loading') }}</span></div>
      </main>
    </div>

    <nav class="mobile-nav" :aria-label="t('menu')">
      <button v-for="item in navigation.slice(0, 4)" :key="item.id" :class="{ active: active === item.id }" @click="navigate(item.id)"><component :is="item.icon" :size="19" /><span>{{ item.label }}</span></button>
      <button :class="{ active: ['devices', 'advanced', 'diagnostics', 'logs'].includes(active) }" @click="moreOpen = !moreOpen"><Menu :size="19" /><span>{{ t('more') }}</span></button>
    </nav>
    <div v-if="moreOpen" class="mobile-more" role="dialog" :aria-label="t('more')">
      <button @click="navigate('devices')"><Network :size="18" />{{ t('devices') }}</button>
      <button @click="navigate('advanced')"><FileCode2 :size="18" />{{ t('advanced') }}</button>
      <button @click="navigate('diagnostics')"><Activity :size="18" />{{ t('diagnostics') }}</button>
      <button @click="navigate('logs')"><ScrollText :size="18" />{{ t('logs') }}</button>
    </div>
  </div>
</template>
