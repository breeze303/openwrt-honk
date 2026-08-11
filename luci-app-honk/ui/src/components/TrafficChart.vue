<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import type { TrafficFrame } from '../types'

const props = defineProps<{ points: TrafficFrame[]; label: string }>()
const canvas = ref<HTMLCanvasElement | null>(null)
let resizeObserver: ResizeObserver | null = null
let themeObserver: MutationObserver | null = null

function draw() {
  const element = canvas.value
  if (!element) return
  const rect = element.getBoundingClientRect()
  const ratio = Math.min(window.devicePixelRatio || 1, 2)
  const width = Math.max(1, Math.round(rect.width * ratio))
  const height = Math.max(1, Math.round(rect.height * ratio))
  if (element.width !== width || element.height !== height) {
    element.width = width
    element.height = height
  }
  const context = element.getContext('2d')
  if (!context) return
  context.clearRect(0, 0, width, height)
  const styles = getComputedStyle(document.documentElement)
  const line = styles.getPropertyValue('--line').trim() || '#dce2e3'
  const downColor = styles.getPropertyValue('--info').trim() || '#2763a6'
  const upColor = styles.getPropertyValue('--warning').trim() || '#a25d00'
  const points = props.points.length ? props.points : [{ up: 0, down: 0 }]
  const maximum = Math.max(1, ...points.flatMap(point => [point.up, point.down]))
  const padding = 10 * ratio
  const chartHeight = height - padding * 2

  context.save()
  context.strokeStyle = line
  context.globalAlpha = 0.7
  context.lineWidth = ratio
  context.setLineDash([3 * ratio, 5 * ratio])
  for (let index = 1; index <= 3; index += 1) {
    const y = padding + (chartHeight / 4) * index
    context.beginPath()
    context.moveTo(padding, y)
    context.lineTo(width - padding, y)
    context.stroke()
  }
  context.restore()

  const coordinates = (key: 'up' | 'down') => points.map((point, index) => ({
    x: points.length === 1 ? width / 2 : padding + (index / (points.length - 1)) * (width - padding * 2),
    y: height - padding - (point[key] / maximum) * chartHeight,
  }))
  const path = (values: Array<{ x: number; y: number }>) => {
    context.beginPath()
    context.moveTo(values[0].x, values[0].y)
    for (let index = 1; index < values.length - 1; index += 1) {
      const current = values[index]
      const next = values[index + 1]
      context.quadraticCurveTo(current.x, current.y, (current.x + next.x) / 2, (current.y + next.y) / 2)
    }
    const last = values[values.length - 1]
    if (values.length > 1) context.quadraticCurveTo(last.x, last.y, last.x, last.y)
  }
  const series = (key: 'up' | 'down', color: string) => {
    const values = coordinates(key)
    path(values)
    context.lineTo(values[values.length - 1].x, height - padding)
    context.lineTo(values[0].x, height - padding)
    context.closePath()
    context.save()
    context.globalAlpha = 0.1
    context.fillStyle = color
    context.fill()
    context.restore()
    path(values)
    context.lineWidth = 2 * ratio
    context.lineJoin = 'round'
    context.lineCap = 'round'
    context.strokeStyle = color
    context.stroke()
  }
  series('down', downColor)
  series('up', upColor)
}

watch(() => props.points, () => void nextTick(draw), { deep: true })
onMounted(() => {
  resizeObserver = new ResizeObserver(draw)
  if (canvas.value) resizeObserver.observe(canvas.value)
  themeObserver = new MutationObserver(draw)
  themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] })
  draw()
})
onBeforeUnmount(() => {
  resizeObserver?.disconnect()
  themeObserver?.disconnect()
})
</script>

<template><canvas ref="canvas" class="traffic-chart" role="img" :aria-label="label" /></template>
