<script setup lang="ts">
import { nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import type { TrafficFrame } from '../api'

const props = defineProps<{ points: TrafficFrame[]; label: string }>()
const canvas = ref<HTMLCanvasElement | null>(null)
let observer: ResizeObserver | null = null

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
  const points = props.points.length ? props.points : [{ up: 0, down: 0 }]
  const max = Math.max(1, ...points.flatMap(point => [point.up, point.down]))

  const padding = 10 * ratio
  const chartHeight = height - padding * 2
  const coordinates = (key: 'up' | 'down') => points.map((point, index) => ({
    x: points.length === 1 ? width / 2 : padding + (index / (points.length - 1)) * (width - padding * 2),
    y: height - padding - (point[key] / max) * chartHeight,
  }))
  const smoothPath = (values: Array<{ x: number; y: number }>) => {
    context.beginPath()
    context.moveTo(values[0].x, values[0].y)
    for (let index = 1; index < values.length - 1; index += 1) {
      const current = values[index]
      const next = values[index + 1]
      const midpointX = (current.x + next.x) / 2
      const midpointY = (current.y + next.y) / 2
      context.quadraticCurveTo(current.x, current.y, midpointX, midpointY)
    }
    if (values.length > 1) {
      const last = values[values.length - 1]
      context.quadraticCurveTo(last.x, last.y, last.x, last.y)
    }
  }
  const drawLine = (key: 'up' | 'down', color: string, fill: string) => {
    const values = coordinates(key)
    context.save()
    context.setLineDash([4 * ratio, 5 * ratio])
    context.strokeStyle = 'rgba(101, 122, 151, 0.14)'
    context.lineWidth = ratio
    for (let index = 1; index <= 3; index += 1) {
      const y = padding + (chartHeight / 4) * index
      context.beginPath()
      context.moveTo(padding, y)
      context.lineTo(width - padding, y)
      context.stroke()
    }
    context.restore()

    smoothPath(values)
    context.lineTo(values[values.length - 1].x, height - padding)
    context.lineTo(values[0].x, height - padding)
    context.closePath()
    context.fillStyle = fill
    context.fill()

    smoothPath(values)
    context.lineWidth = 2.25 * ratio
    context.lineJoin = 'round'
    context.lineCap = 'round'
    context.strokeStyle = color
    context.shadowColor = color
    context.shadowBlur = 5 * ratio
    context.stroke()
    context.shadowBlur = 0
  }
  drawLine('down', '#2f73e8', 'rgba(47, 115, 232, 0.12)')
  drawLine('up', '#e68267', 'rgba(230, 130, 103, 0.10)')
}

watch(() => props.points, () => void nextTick(draw), { deep: true })
onMounted(() => {
  observer = new ResizeObserver(draw)
  if (canvas.value) observer.observe(canvas.value)
  draw()
})
onBeforeUnmount(() => observer?.disconnect())
</script>

<template>
  <canvas ref="canvas" class="traffic-sparkline" role="img" :aria-label="label" />
</template>
