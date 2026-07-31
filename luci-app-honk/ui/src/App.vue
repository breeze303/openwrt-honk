<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import {
  Cable,
  Gauge,
  LayoutDashboard,
  ListFilter,
  MoreHorizontal,
  Play,
  Power,
  RefreshCw,
  RotateCcw,
  ScrollText,
  Settings,
  Waypoints,
  X,
} from '@lucide/vue'
import ConfigView from './ConfigView.vue'
import ConnectionsView from './views/ConnectionsView.vue'
import LogsView from './views/LogsView.vue'
import OverviewView from './views/OverviewView.vue'
import ProxiesView from './views/ProxiesView.vue'
import RulesView from './views/RulesView.vue'
import { useRuntime } from './composables/useRuntime'

type ViewName = 'overview' | 'proxies' | 'connections' | 'rules' | 'settings' | 'logs'

const validViews: ViewName[] = ['overview', 'proxies', 'connections', 'rules', 'settings', 'logs']
const initial = window.location.hash.replace(/^#\/?/, '') as ViewName
const activeView = ref<ViewName>(validViews.includes(initial) ? initial : 'overview')
const moreOpen = ref(false)
const notice = ref('')
const runtime = useRuntime()

const navigation = [
  { id: 'overview' as const, label: '概览', icon: LayoutDashboard },
  { id: 'proxies' as const, label: '节点', icon: Waypoints },
  { id: 'connections' as const, label: '连接', icon: Cable },
  { id: 'rules' as const, label: '规则', icon: ListFilter },
  { id: 'settings' as const, label: '配置', icon: Settings },
  { id: 'logs' as const, label: '日志', icon: ScrollText },
]
const mobileNavigation = navigation.slice(0, 4)
const currentLabel = computed(() => navigation.find(item => item.id === activeView.value)?.label || 'Honk')

function navigate(view: ViewName) {
  activeView.value = view
  moreOpen.value = false
  window.location.hash = `/${view}`
}

function onHashChange() {
  const next = window.location.hash.replace(/^#\/?/, '') as ViewName
  if (validViews.includes(next)) activeView.value = next
}

async function runAction(action: () => Promise<unknown>, success = '') {
  notice.value = ''
  try {
    await action()
    notice.value = success
    if (success) window.setTimeout(() => { notice.value = '' }, 3000)
  } catch (reason) {
    runtime.error.value = (reason as Error).message
  }
}

onMounted(() => {
  window.addEventListener('hashchange', onHashChange)
  void runtime.initialize()
})
onBeforeUnmount(() => window.removeEventListener('hashchange', onHashChange))
</script>

<template>
  <div class="app-shell">
    <aside class="app-sidebar" aria-label="Honk 主导航">
      <div class="brand-mark" aria-label="Honk">H</div>
      <nav>
        <button v-for="item in navigation" :key="item.id" :class="{ active: activeView === item.id }" :title="item.label" @click="navigate(item.id)">
          <component :is="item.icon" :size="19" /><span>{{ item.label }}</span>
        </button>
      </nav>
      <div class="sidebar-foot">
        <span class="status-dot" :class="{ online: runtime.running.value }" />
        <small>{{ runtime.running.value ? '运行中' : '已停止' }}</small>
      </div>
    </aside>

    <div class="app-workspace">
      <header class="app-topbar">
        <div class="mobile-title"><span class="brand-mark small">H</span><strong>{{ currentLabel }}</strong></div>
        <div class="runtime-status" role="status">
          <span class="status-dot" :class="{ online: runtime.running.value }" />
          <div><strong>{{ runtime.running.value ? 'Honk 正在运行' : 'Honk 已停止' }}</strong><span>{{ runtime.running.value ? `${runtime.connections.value.connections.length} 个活动连接` : '透明代理未接管流量' }}</span></div>
        </div>
        <div class="topbar-actions">
          <button class="icon-button" title="刷新运行数据" aria-label="刷新运行数据" :disabled="runtime.loading.value" @click="() => runtime.initialize()"><RefreshCw :size="17" /></button>
          <template v-if="runtime.running.value">
            <button class="icon-button" title="重启服务" aria-label="重启服务" :disabled="runtime.busy.value" @click="runtime.service('restart')"><RotateCcw :size="17" /></button>
            <button class="danger-button" :disabled="runtime.busy.value" @click="runtime.service('stop')"><Power :size="17" />停止服务</button>
          </template>
          <button v-else class="primary-button" :disabled="runtime.busy.value" @click="runtime.service('start')"><Play :size="17" />启动服务</button>
        </div>
      </header>

      <p v-if="runtime.error.value" class="app-alert" role="alert"><span>{{ runtime.error.value }}</span><button class="icon-button" title="关闭提示" aria-label="关闭提示" @click="runtime.error.value = ''"><X :size="16" /></button></p>
      <p v-if="notice" class="app-notice" role="status">{{ notice }}</p>

      <main class="app-content" :aria-busy="runtime.loading.value">
        <OverviewView
          v-if="activeView === 'overview'"
          :running="runtime.running.value"
          :mode="runtime.config.value.mode"
          :traffic="runtime.traffic.value"
          :history="runtime.trafficHistory.value"
          :memory="runtime.memory.value"
          :connections="runtime.connections.value"
          :outbounds="runtime.stats.value.outbounds"
          :node-count="runtime.nodes.value.length || runtime.bootstrap.value?.configuredNodeCount || 0"
          :proxies="runtime.proxies.value.proxies"
          :rules="runtime.rules.value"
          @mode="value => runAction(() => runtime.setMode(value), '代理模式已更新')"
        />
        <ProxiesView
          v-else-if="activeView === 'proxies'"
          :running="runtime.running.value"
          :proxies="runtime.proxies.value.proxies"
          :subscriptions="runtime.subscriptions.value.subscriptions"
          :busy="runtime.busy.value"
          @select="(group, name) => runAction(() => runtime.selectProxy(group, name), `已切换到 ${name}`)"
          @test-proxy="(name, url) => runAction(async () => { const delay = await runtime.testProxy(name, url); notice = `${name} · ${delay} ms` })"
          @test-group="(name, url) => runAction(() => runtime.testGroup(name, url), `${name} 测速完成`)"
          @refresh-subscription="name => runAction(() => runtime.refreshSubscription(name), `${name} 正在更新`)"
          @changed="() => runtime.initialize()"
        />
        <ConnectionsView
          v-else-if="activeView === 'connections'"
          :running="runtime.running.value"
          :connections="runtime.connections.value.connections"
          @close="id => runAction(() => runtime.closeConnection(id))"
          @close-all="runAction(() => runtime.closeAllConnections(), '活动连接已关闭')"
        />
        <RulesView v-else-if="activeView === 'rules'" :running="runtime.running.value" :rules="runtime.rules.value.rules" />
        <ConfigView v-else-if="activeView === 'settings'" />
        <LogsView v-else :logs="runtime.logs.value" />

        <div v-if="runtime.loading.value" class="loading-layer" aria-live="polite"><Gauge :size="22" class="spin" /><span>正在读取 Honk 状态</span></div>
      </main>
    </div>

    <nav class="mobile-nav" aria-label="Honk 移动导航">
      <button v-for="item in mobileNavigation" :key="item.id" :class="{ active: activeView === item.id }" @click="navigate(item.id)"><component :is="item.icon" :size="19" /><span>{{ item.label }}</span></button>
      <button :class="{ active: activeView === 'settings' || activeView === 'logs' }" @click="moreOpen = !moreOpen"><MoreHorizontal :size="19" /><span>更多</span></button>
    </nav>
    <div v-if="moreOpen" class="mobile-more" role="dialog" aria-label="更多页面">
      <button @click="navigate('settings')"><Settings :size="18" />配置管理</button>
      <button @click="navigate('logs')"><ScrollText :size="18" />运行日志</button>
    </div>
  </div>
</template>
