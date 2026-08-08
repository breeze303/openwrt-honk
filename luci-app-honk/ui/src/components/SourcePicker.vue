<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue'
import { Check, ChevronDown, ChevronRight, RadioTower, Search, Server, Waypoints, X } from '@lucide/vue'

export type SourcePickerKind = 'node' | 'subscription' | 'runtime'

export type SourcePickerOption = {
  value: string
  label: string
  detail: string
  kind: SourcePickerKind
  searchText: string
}

export type SourcePickerGroup = {
  id: string
  label: string
  count: number
  options: SourcePickerOption[]
}

const props = withDefaults(defineProps<{
  modelValue: string
  groups: SourcePickerGroup[]
  disabled?: boolean
  placeholder: string
  searchPlaceholder: string
  emptyLabel: string
  ariaLabel: string
}>(), { disabled: false })

const emit = defineEmits<{ 'update:modelValue': [value: string] }>()

const open = ref(false)
const query = ref('')
const expandedGroup = ref<string | null>(null)
const trigger = ref<HTMLButtonElement | null>(null)
const panel = ref<HTMLElement | null>(null)
const searchInput = ref<HTMLInputElement | null>(null)
let frame = 0

const allOptions = computed(() => props.groups.flatMap(group => group.options))
const selected = computed(() => allOptions.value.find(option => option.value === props.modelValue))
const selectedGroup = computed(() => props.groups.find(group => group.options.some(option => option.value === props.modelValue))?.id || null)
const normalizedQuery = computed(() => query.value.trim().toLocaleLowerCase())
const visibleGroups = computed(() => props.groups.map(group => ({
  ...group,
  options: group.options.filter(option => !normalizedQuery.value || option.searchText.includes(normalizedQuery.value)),
})).filter(group => group.options.length > 0))

function iconFor(option: SourcePickerOption) {
  if (option.kind === 'subscription') return RadioTower
  return option.kind === 'runtime' ? Waypoints : Server
}

function queuePosition() {
  if (frame) return
  frame = window.requestAnimationFrame(() => {
    frame = 0
    positionPanel()
  })
}

function positionPanel() {
  const triggerElement = trigger.value
  const panelElement = panel.value
  if (!open.value || !triggerElement || !panelElement) return

  const rect = triggerElement.getBoundingClientRect()
  const viewportWidth = window.innerWidth || document.documentElement.clientWidth
  const viewportHeight = window.innerHeight || document.documentElement.clientHeight
  const width = Math.min(Math.max(rect.width, 300), Math.max(0, viewportWidth - 24))
  const maxHeight = Math.min(Math.floor(viewportHeight * 0.62), 520)

  panelElement.style.visibility = 'hidden'
  panelElement.style.height = 'auto'
  panelElement.style.width = `${width}px`
  panelElement.style.maxHeight = `${maxHeight}px`
  panelElement.style.left = '0px'
  panelElement.style.top = '0px'

  const panelHeight = Math.min(panelElement.scrollHeight, maxHeight)
  panelElement.style.height = `${panelHeight}px`
  const spaceBelow = viewportHeight - rect.bottom
  const spaceAbove = rect.top
  const opensUpward = spaceBelow < panelHeight && spaceAbove > spaceBelow
  const top = opensUpward
    ? Math.max(12, rect.top - panelHeight - 6)
    : Math.min(Math.max(12, rect.bottom + 6), Math.max(12, viewportHeight - panelHeight - 12))
  const left = Math.min(Math.max(12, rect.left), Math.max(12, viewportWidth - width - 12))

  panelElement.style.left = `${left}px`
  panelElement.style.top = `${top}px`
  panelElement.style.visibility = 'visible'
}

function close() {
  open.value = false
  query.value = ''
}

function openPanel() {
  if (props.disabled || allOptions.value.length === 0) return
  open.value = true
  query.value = ''
  expandedGroup.value = selectedGroup.value || props.groups[0]?.id || null
  void nextTick(() => {
    positionPanel()
    searchInput.value?.focus()
  })
}

function togglePanel() {
  if (open.value) close()
  else openPanel()
}

function toggleGroup(id: string) {
  if (normalizedQuery.value) return
  expandedGroup.value = expandedGroup.value === id ? null : id
  queuePosition()
}

function isExpanded(id: string) {
  return normalizedQuery.value !== '' || expandedGroup.value === id
}

function choose(option: SourcePickerOption) {
  if (option.value !== props.modelValue) emit('update:modelValue', option.value)
  close()
  trigger.value?.focus()
}

function clearSearch() {
  query.value = ''
  searchInput.value?.focus()
  void nextTick(positionPanel)
}

function handleDocumentPointerDown(event: PointerEvent) {
  const target = event.target
  if (!(target instanceof Node)) return
  if (!panel.value?.contains(target) && !trigger.value?.contains(target)) close()
}

function handleKeydown(event: KeyboardEvent) {
  if (event.key === 'Escape' && open.value) {
    event.preventDefault()
    close()
    trigger.value?.focus()
  }
}

function handleWindowScroll(event: Event) {
  const target = event.target
  if (target instanceof Node && panel.value?.contains(target)) return
  queuePosition()
}

watch(query, () => void nextTick(positionPanel))
watch(open, visible => {
  if (visible) {
    document.addEventListener('pointerdown', handleDocumentPointerDown)
    window.addEventListener('resize', queuePosition)
    window.addEventListener('scroll', handleWindowScroll, true)
    window.addEventListener('keydown', handleKeydown)
  } else {
    document.removeEventListener('pointerdown', handleDocumentPointerDown)
    window.removeEventListener('resize', queuePosition)
    window.removeEventListener('scroll', handleWindowScroll, true)
    window.removeEventListener('keydown', handleKeydown)
  }
})

onBeforeUnmount(() => {
  document.removeEventListener('pointerdown', handleDocumentPointerDown)
  window.removeEventListener('resize', queuePosition)
  window.removeEventListener('scroll', handleWindowScroll, true)
  window.removeEventListener('keydown', handleKeydown)
  if (frame) window.cancelAnimationFrame(frame)
})
</script>

<template>
  <div class="source-picker">
    <button ref="trigger" class="source-picker-trigger" type="button" :disabled="disabled || allOptions.length === 0" :aria-label="ariaLabel" aria-haspopup="dialog" :aria-expanded="open" @click="togglePanel">
      <Server :size="18" />
      <span class="source-picker-value" :title="selected?.label || placeholder">{{ selected?.label || placeholder }}</span>
      <ChevronDown :size="18" :class="{ rotated: open }" />
    </button>

    <Teleport to="body">
      <section v-if="open" ref="panel" class="source-picker-panel" role="dialog" :aria-label="ariaLabel">
        <div class="source-picker-search">
          <Search :size="17" />
          <input ref="searchInput" v-model="query" type="search" :placeholder="searchPlaceholder" autocomplete="off" />
          <button v-if="query" class="source-picker-clear" type="button" :aria-label="searchPlaceholder" @click="clearSearch"><X :size="15" /></button>
        </div>

        <div v-if="visibleGroups.length" class="source-picker-groups">
          <section v-for="group in visibleGroups" :key="group.id" class="source-picker-group" :class="{ expanded: isExpanded(group.id) }">
            <button class="source-picker-group-heading" type="button" :aria-expanded="isExpanded(group.id)" @click="toggleGroup(group.id)">
              <ChevronDown v-if="isExpanded(group.id)" :size="16" /><ChevronRight v-else :size="16" />
              <strong>{{ group.label }}</strong><span>{{ group.count }}</span>
            </button>
            <div v-show="isExpanded(group.id)" class="source-picker-options" role="listbox" :aria-label="group.label">
              <button v-for="option in group.options" :key="option.value" class="source-picker-option" :class="{ selected: option.value === modelValue }" type="button" role="option" :aria-selected="option.value === modelValue" @click="choose(option)">
                <component :is="iconFor(option)" :size="16" />
                <span class="source-picker-option-copy"><strong>{{ option.label }}</strong><small>{{ option.detail }}</small></span>
                <Check v-if="option.value === modelValue" :size="16" />
              </button>
            </div>
          </section>
        </div>
        <p v-else class="source-picker-empty">{{ emptyLabel }}</p>
      </section>
    </Teleport>
  </div>
</template>
