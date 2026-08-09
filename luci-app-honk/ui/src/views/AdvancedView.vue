<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { AlertTriangle, CheckCircle2, FileCode2, Network, Power, RadioTower, RefreshCw, RotateCcw, ScrollText, Settings2, ShieldCheck } from '@lucide/vue'
import { api } from '../api'
import { t } from '../i18n'
import type { PageAction } from '../page-actions'
import type { DialMode, LogLevel, NetworkDiscovery, StateResponse } from '../types'

const emit = defineEmits<{ changed: []; notice: [message: string]; error: [message: string]; pageActions: [actions: PageAction[]] }>()
const source = ref('')
const revision = ref('')
const loading = ref(true)
const busy = ref(false)
const valid = ref(false)
const clashApi = ref<StateResponse['clashApi']>({ enabled: false, controller: '', secretConfigured: false })
const discovery = ref<NetworkDiscovery | null>(null)
const lanDevice = ref('')
const wanDevice = ref('')
const dialMode = ref<DialMode>('domain')
const logLevel = ref<LogLevel>('info')
const dnsmasqForwarding = ref(true)
const localDnsServers = ref('')
const localDnsEndpoint = ref('127.0.0.1#1053')
const dnsmasqStatus = ref('')
const interfaceBusy = ref(false)
const loadedSource = ref('')
type AdvancedTab = 'global' | 'config'
const activeTab = ref<AdvancedTab>('global')

function tabFromHash(): AdvancedTab {
  return window.location.hash.replace(/^#\/?/, '') === 'advanced/config' ? 'config' : 'global'
}

function tabHash(tab: AdvancedTab): string {
  return `#/advanced/${tab}`
}

function configIsDirty(): boolean {
  return activeTab.value === 'config' && source.value !== loadedSource.value
}

function activateTab(tab: AdvancedTab, updateHash = true): boolean {
  if (tab === activeTab.value) return true
  if (configIsDirty() && !window.confirm(t('advancedTabDiscardConfirm'))) return false
  activeTab.value = tab
  if (updateHash && window.location.hash !== tabHash(tab)) window.location.hash = tabHash(tab)
  void load()
  return true
}

function handleHashChange() {
  const path = window.location.hash.replace(/^#\/?/, '')
  if (path !== 'advanced' && path !== 'advanced/global' && path !== 'advanced/config') return
  const requested = tabFromHash()
  if (requested === activeTab.value) return
  if (!activateTab(requested, false)) window.history.replaceState(null, '', tabHash(activeTab.value))
}

function globalSection(content: string): { open: number; close: number } | null {
  const header = /(?:^|\n)(?![ \t]*#)[ \t]*global[ \t]*\{/.exec(content)
  if (!header || header.index === undefined) return null
  const open = content.indexOf('{', header.index)
  if (open < 0) return null
  let depth = 1
  let quote = ''
  let escaped = false
  let comment = false
  for (let index = open + 1; index < content.length; index += 1) {
    const character = content[index]
    if (comment) {
      if (character === '\n') comment = false
      continue
    }
    if (quote) {
      if (escaped) escaped = false
      else if (character === '\\') escaped = true
      else if (character === quote) quote = ''
      continue
    }
    if (character === '#') {
      comment = true
    } else if (character === "'" || character === '"') {
      quote = character
    } else if (character === '{') {
      depth += 1
    } else if (character === '}') {
      depth -= 1
      if (depth === 0) return { open, close: index }
    }
  }
  return null
}

function quoteConfigValue(value: string): string {
  return `'${value.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`
}

function syncGlobalOption(content: string, key: string, value: string): string {
  const pattern = new RegExp(`(^|\\n)([ \\t]*)${key}([ \\t]*:[ \\t]*)[^\\n]*`, 'gm')
  let found = false
  const updated = content.replace(pattern, (_line, prefix: string, indent: string, separator: string) => {
    if (found) return prefix
    found = true
    return `${prefix}${indent}${key}${separator}${quoteConfigValue(value)}`
  })
  if (found) return updated
  const trailing = content.match(/\s*$/)?.[0] || ''
  const head = content.slice(0, content.length - trailing.length)
  return `${head}\n\t${key}: ${quoteConfigValue(value)}${trailing}`
}

function syncNetworkOptions(content: string): string {
  if (!lanDevice.value || !wanDevice.value) return content
  const section = globalSection(content)
  if (!section) return content
  let body = content.slice(section.open + 1, section.close)
  body = syncGlobalOption(body, 'lan_interface', lanDevice.value)
  body = syncGlobalOption(body, 'wan_interface', wanDevice.value)
  body = syncGlobalOption(body, 'dial_mode', dialMode.value)
  return content.slice(0, section.open + 1) + body + content.slice(section.close)
}

function configuredLogLevel(content: string): LogLevel {
  const section = globalSection(content)
  if (!section) return 'info'
  const value = content.slice(section.open + 1, section.close).match(/(?:^|\n)\s*log_level\s*:\s*([^#\n]+)/)?.[1]?.trim() || ''
  const normalized = value.replace(/^['"]|['"]$/g, '').toLowerCase()
  return normalized === 'trace' || normalized === 'debug' || normalized === 'info' || normalized === 'warn' || normalized === 'error' ? normalized : 'info'
}

async function load(preferredConfig = '') {
  loading.value = true
  try {
    const state = await api.advanced()
    source.value = preferredConfig || state.config || ''
    if (!source.value) {
      try {
        source.value = (await api.defaultConfig()).content
      } catch {
        // The service reports the missing-template error through the normal page state.
      }
    }
    loadedSource.value = source.value
    logLevel.value = configuredLogLevel(source.value)
    revision.value = state.revision
    clashApi.value = state.clashApi || { enabled: false, controller: '', secretConfigured: false }
    dnsmasqForwarding.value = state.localDns?.enabled ?? true
    localDnsServers.value = state.localDns?.servers || ''
    localDnsEndpoint.value = state.localDns?.endpoint || '127.0.0.1#1053'
    dnsmasqStatus.value = state.localDns?.active ? t('dnsmasqActive') : t('dnsmasqInactive')
    valid.value = false
    const network = await api.networkInterfaces()
    discovery.value = network
    lanDevice.value = network.current?.lan && network.current.lan !== 'auto' ? network.current.lan : (network.recommended.lan || '')
    wanDevice.value = network.current?.wan && network.current.wan !== 'auto' ? network.current.wan : (network.recommended.wan || '')
    dialMode.value = network.current?.dialMode || 'domain'
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    loading.value = false
  }
}

async function applyInterfaces() {
  if (!lanDevice.value || !wanDevice.value) {
    emit('error', t('interfaceUnavailable'))
    return
  }
  if (!window.confirm(t('globalSettingsApplyConfirm'))) return
  interfaceBusy.value = true
  try {
    const result = await api.applyInterfaces({ lanDevice: lanDevice.value, wanDevice: wanDevice.value, dialMode: dialMode.value, logLevel: logLevel.value, dnsmasqForwarding: dnsmasqForwarding.value, expectedRevision: revision.value })
    if (result.config) source.value = result.config
    if (result.revision) revision.value = result.revision
    emit('notice', t('globalSettingsApplied'))
    emit('changed')
    await load(result.config || '')
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    interfaceBusy.value = false
  }
}

async function refreshDiscovery() {
  interfaceBusy.value = true
  try {
    const result = await api.networkInterfaces()
    discovery.value = result
    if (result.current?.lan && result.current.lan !== 'auto') lanDevice.value = result.current.lan
    else if (result.recommended.lan) lanDevice.value = result.recommended.lan
    if (result.current?.wan && result.current.wan !== 'auto') wanDevice.value = result.current.wan
    else if (result.recommended.wan) wanDevice.value = result.recommended.wan
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    interfaceBusy.value = false
  }
}

async function toggleClashApi() {
  const enabled = !clashApi.value.enabled
  if (!window.confirm(enabled ? t('clashApiEnableConfirm') : t('clashApiDisableConfirm'))) return
  busy.value = true
  try {
    await api.toggleClashApi(enabled, revision.value)
    emit('notice', t('applySuccess'))
    emit('changed')
    await load()
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    busy.value = false
  }
}

async function validate() {
  busy.value = true
  valid.value = false
  try {
    source.value = syncNetworkOptions(source.value)
    await api.validateAdvanced(source.value)
    valid.value = true
    emit('notice', t('valid'))
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    busy.value = false
  }
}

async function apply() {
  if (!window.confirm(t('advancedWarning'))) return
  busy.value = true
  try {
    source.value = syncNetworkOptions(source.value)
    await api.applyAdvanced(source.value, revision.value)
    emit('notice', t('applySuccess'))
    emit('changed')
    await load()
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    busy.value = false
  }
}

async function restoreDefault() {
  if (!window.confirm(t('restoreDefaultConfirm'))) return
  busy.value = true
  try {
    await api.resetConfig(revision.value)
    emit('notice', t('defaultRestored'))
    emit('changed')
    await load()
  } catch (reason) {
    emit('error', (reason as Error).message)
  } finally {
    busy.value = false
  }
}

function publishPageActions() {
  const action: PageAction = activeTab.value === 'config'
    ? {
        id: 'apply-advanced-config',
        label: t('confirmApply'),
        disabled: busy.value || loading.value,
        busy: busy.value,
        run: apply,
      }
    : {
        id: 'apply-interfaces',
        label: t('applyGlobalSettings'),
        disabled: busy.value || loading.value || interfaceBusy.value || !lanDevice.value || !wanDevice.value,
        busy: busy.value || interfaceBusy.value,
        run: applyInterfaces,
      }
  emit('pageActions', [action])
}

watch([activeTab, busy, loading, interfaceBusy, lanDevice, wanDevice, logLevel, dnsmasqForwarding, localDnsServers, localDnsEndpoint], publishPageActions, { immediate: true })

onMounted(() => {
  activeTab.value = tabFromHash()
  if (window.location.hash.replace(/^#\/?/, '') === 'advanced') window.history.replaceState(null, '', tabHash(activeTab.value))
  window.addEventListener('hashchange', handleHashChange)
  void load()
})
onBeforeUnmount(() => window.removeEventListener('hashchange', handleHashChange))
</script>

<template>
  <div class="page advanced-page">
    <div class="segmented advanced-tabs" role="tablist" :aria-label="t('advancedTabs')">
      <button type="button" role="tab" :aria-selected="activeTab === 'global'" :class="{ active: activeTab === 'global' }" @click="activateTab('global')"><Settings2 :size="17" />{{ t('globalSettings') }}</button>
      <button type="button" role="tab" :aria-selected="activeTab === 'config'" :class="{ active: activeTab === 'config' }" @click="activateTab('config')"><FileCode2 :size="17" />{{ t('fullConfigPage') }}</button>
    </div>

    <template v-if="activeTab === 'global'">
    <section class="tool-panel clash-api-panel" :aria-busy="busy">
      <header class="clash-api-heading">
        <div class="clash-api-title"><RadioTower :size="20" /><div><h2>{{ t('clashApi') }}</h2><p>{{ t('clashApiHint') }}</p></div></div>
        <span class="clash-api-status" :class="clashApi.enabled ? 'enabled' : 'disabled'">{{ clashApi.enabled ? t('clashApiEnabled') : t('clashApiDisabled') }}</span>
      </header>
      <div class="clash-api-actions">
        <code v-if="clashApi.enabled && clashApi.controller">{{ clashApi.controller }}</code><span v-else />
        <button :class="clashApi.enabled ? 'secondary-button' : 'primary-command'" :disabled="busy || loading" @click="toggleClashApi"><Power :size="17" />{{ clashApi.enabled ? t('disableClashApi') : t('enableClashApi') }}</button>
      </div>
    </section>
    <section class="tool-panel log-level-panel">
      <header class="section-heading">
        <div class="clash-api-title"><ScrollText :size="20" /><div><h2>{{ t('logSettings') }}</h2><p>{{ t('logLevelHint') }}</p></div></div>
      </header>
      <label class="log-level-field"><span>{{ t('logLevel') }}</span><select v-model="logLevel" :disabled="busy || loading || interfaceBusy"><option value="trace">{{ t('logLevelTrace') }}</option><option value="debug">{{ t('logLevelDebug') }}</option><option value="info">{{ t('logLevelInfo') }}</option><option value="warn">{{ t('logLevelWarn') }}</option><option value="error">{{ t('logLevelError') }}</option></select></label>
    </section>
    <section class="tool-panel interface-panel" :aria-busy="interfaceBusy">
      <header class="interface-heading">
        <div class="clash-api-title"><Network :size="20" /><div><h2>{{ t('networkBinding') }}</h2><p>{{ t('networkBindingHint') }}</p></div></div>
        <button class="secondary-button compact-command" :disabled="busy || loading || interfaceBusy" @click="refreshDiscovery"><RefreshCw :size="16" :class="interfaceBusy ? 'spin' : ''" />{{ t('refreshDiscovery') }}</button>
      </header>
      <div v-if="discovery?.ambiguous" class="inline-warning"><AlertTriangle :size="16" />{{ t('interfaceAmbiguous') }}</div>
      <div v-else-if="!discovery?.candidates?.length" class="inline-warning"><AlertTriangle :size="16" />{{ t('interfaceUnavailable') }}</div>
      <div class="network-grid">
        <label><span>{{ t('lanInterface') }}</span><select v-model="lanDevice" :disabled="busy || loading || interfaceBusy"><option value="">{{ t('interfaceAuto') }}</option><option v-for="item in discovery?.candidates || []" :key="`lan-${item.l3Device}`" :value="item.l3Device">{{ item.l3Device }} · {{ item.logicalName || item.kind }}</option></select></label>
        <label><span>{{ t('wanInterface') }}</span><select v-model="wanDevice" :disabled="busy || loading || interfaceBusy"><option value="">{{ t('interfaceAuto') }}</option><option v-for="item in discovery?.candidates || []" :key="`wan-${item.l3Device}`" :value="item.l3Device">{{ item.l3Device }} · {{ item.logicalName || item.kind }}</option></select></label>
        <label class="dial-mode-field"><span>{{ t('dialMode') }}</span><select v-model="dialMode" :disabled="busy || loading || interfaceBusy"><option value="ip">{{ t('dialModeIp') }}</option><option value="domain">{{ t('dialModeDomain') }}</option><option value="domain+">{{ t('dialModePlus') }}</option><option value="domain++">{{ t('dialModePlusPlus') }}</option></select><small>{{ t('dialModeHint') }}</small></label>
        <label class="local-dns-field"><span>{{ t('dnsmasqForwarding') }}</span><input v-model="dnsmasqForwarding" type="checkbox" :disabled="busy || loading || interfaceBusy" /><small>{{ t('dnsmasqForwardingHint') }}</small></label>
        <label class="local-dns-servers-field"><span>{{ t('dnsmasqListener') }}</span><input :value="localDnsEndpoint" type="text" readonly disabled /><small>{{ dnsmasqStatus }} · {{ t('dnsmasqListenerHint') }}</small></label>
        <label class="local-dns-servers-field"><span>{{ t('localDnsServers') }}</span><input :value="localDnsServers" type="text" readonly disabled /><small>{{ t('localDnsServersHint') }}</small></label>
        <div class="network-candidates"><span>{{ t('interfaceCandidates') }}</span><div v-for="item in discovery?.candidates || []" :key="item.l3Device" class="network-candidate"><strong>{{ item.l3Device }}</strong><small>{{ item.logicalName || item.kind }} · {{ item.up ? t('interfaceStatusUp') : t('interfaceStatusDown') }}<template v-if="item.defaultRoute"> · {{ t('interfaceRoute') }} {{ item.defaultRoute.metric }}</template></small></div><p v-if="!discovery?.candidates?.length">{{ t('interfaceUnknown') }}</p></div>
      </div>
      <div class="interface-actions"><span v-if="discovery?.recommended?.lan && discovery?.recommended?.wan">{{ t('interfaceRecommended') }}: {{ discovery.recommended.lan }} / {{ discovery.recommended.wan }}</span></div>
    </section>
    </template>

    <template v-else>
    <div class="warning-band"><AlertTriangle :size="19" /><p>{{ t('advancedWarning') }}</p></div>
    <section class="editor-shell" :aria-busy="loading">
      <header><div><h2>{{ t('rawConfig') }}</h2><code>{{ revision.slice(0, 12) || '—' }}</code></div><button class="secondary-button" :disabled="busy || loading" @click="restoreDefault"><RotateCcw :size="17" />{{ t('restoreDefault') }}</button></header>
      <textarea v-model="source" spellcheck="false" aria-label="config.dae" />
    </section>
    <div class="sticky-actions split">
      <span v-if="valid" class="valid-label"><CheckCircle2 :size="17" />{{ t('valid') }}</span><span v-else />
      <button class="secondary-button" :disabled="busy || loading" @click="validate"><ShieldCheck :size="18" />{{ t('validate') }}</button>
    </div>
    </template>
  </div>
</template>
