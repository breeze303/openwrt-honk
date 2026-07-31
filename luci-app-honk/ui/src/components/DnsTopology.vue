<script setup lang="ts">
import { computed } from 'vue'
import { ChevronRight, Globe2, Network, Router, ShieldCheck, Waypoints } from '@lucide/vue'
import type { DnsUpstream } from '../api'

type DnsTopologyLabels = {
  title: string
  hint: string
  countSuffix: string
  lan: string
  lanDetail: string
  service: string
  serviceDetail: string
  direct: string
  proxy: string
  noDirect: string
  noProxy: string
  noUpstreams: string
  edit: string
}

const defaultLabels: DnsTopologyLabels = {
  title: 'DNS path',
  hint: 'Direct and proxied upstreams',
  countSuffix: ' upstreams',
  lan: 'LAN / DNS request',
  lanDetail: 'Incoming query',
  service: 'Honk DNS',
  serviceDetail: 'Resolve request',
  direct: 'Direct',
  proxy: 'Proxy',
  noDirect: 'No direct upstream',
  noProxy: 'No proxied upstream',
  noUpstreams: 'Add a DNS upstream to draw the path.',
  edit: 'Edit upstream',
}

const props = defineProps<{
  upstreams: DnsUpstream[]
  labels?: Partial<DnsTopologyLabels>
}>()

const emit = defineEmits<{ edit: [name: string] }>()
const labels = computed(() => ({ ...defaultLabels, ...props.labels }))
const directUpstreams = computed(() => props.upstreams.filter(upstream => !upstream.outbound || upstream.outbound === 'direct'))
const proxyUpstreams = computed(() => props.upstreams.filter(upstream => upstream.outbound && upstream.outbound !== 'direct'))

function endpoint(upstream: DnsUpstream): string {
  const host = upstream.host.includes(':') && !upstream.host.startsWith('[')
    ? `[${upstream.host}]`
    : upstream.host
  const path = upstream.path && upstream.path !== '/' ? upstream.path : ''
  return `${upstream.protocol}://${host}:${upstream.port}${path}`
}
</script>

<template>
  <section class="panel dns-topology-panel" aria-labelledby="dns-topology-title">
    <div class="panel-title dns-topology-heading">
      <div>
        <div class="dns-topology-title-row">
          <Waypoints :size="17" aria-hidden="true" />
          <h2 id="dns-topology-title">{{ labels.title }}</h2>
        </div>
        <p class="hint">{{ labels.hint }}</p>
      </div>
      <span class="dns-topology-count">{{ upstreams.length }}{{ labels.countSuffix }}</span>
    </div>

    <div class="dns-topology-canvas">
      <div class="dns-topology-flow dns-topology-entry">
        <div class="dns-topology-node dns-topology-node-entry">
          <Router :size="18" aria-hidden="true" />
          <strong>{{ labels.lan }}</strong>
          <span>{{ labels.lanDetail }}</span>
        </div>
        <ChevronRight class="dns-topology-link" :size="18" aria-hidden="true" />
        <div class="dns-topology-node dns-topology-node-service">
          <ShieldCheck :size="18" aria-hidden="true" />
          <strong>{{ labels.service }}</strong>
          <span>{{ labels.serviceDetail }}</span>
        </div>
      </div>

      <div v-if="upstreams.length" class="dns-topology-simple-groups">
        <section class="dns-topology-simple-group direct" :aria-label="labels.direct">
          <header class="dns-topology-simple-group-head">
            <span class="dns-topology-simple-group-icon"><Globe2 :size="16" aria-hidden="true" /></span>
            <strong>{{ labels.direct }}</strong>
            <span>{{ directUpstreams.length }}</span>
          </header>
          <div v-if="directUpstreams.length" class="dns-topology-simple-list">
            <button v-for="upstream in directUpstreams" :key="upstream.name" class="dns-topology-simple-node" type="button" :title="labels.edit" @click="emit('edit', upstream.name)">
              <span class="dns-topology-simple-node-main"><strong>{{ upstream.name }}</strong><code>{{ endpoint(upstream) }}</code></span>
              <ChevronRight :size="16" aria-hidden="true" />
            </button>
          </div>
          <p v-else class="dns-topology-simple-empty">{{ labels.noDirect }}</p>
        </section>

        <section class="dns-topology-simple-group proxy" :aria-label="labels.proxy">
          <header class="dns-topology-simple-group-head">
            <span class="dns-topology-simple-group-icon"><Network :size="16" aria-hidden="true" /></span>
            <strong>{{ labels.proxy }}</strong>
            <span>{{ proxyUpstreams.length }}</span>
          </header>
          <div v-if="proxyUpstreams.length" class="dns-topology-simple-list">
            <button v-for="upstream in proxyUpstreams" :key="upstream.name" class="dns-topology-simple-node" type="button" :title="labels.edit" @click="emit('edit', upstream.name)">
              <span class="dns-topology-simple-node-main"><strong>{{ upstream.name }}</strong><code>{{ endpoint(upstream) }}</code></span>
              <span class="dns-topology-simple-outbound">{{ upstream.outbound }}</span>
              <ChevronRight :size="16" aria-hidden="true" />
            </button>
          </div>
          <p v-else class="dns-topology-simple-empty">{{ labels.noProxy }}</p>
        </section>
      </div>
      <div v-else class="dns-topology-empty">
        <Network :size="18" aria-hidden="true" />
        <span>{{ labels.noUpstreams }}</span>
      </div>
    </div>
  </section>
</template>
