import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  base: './',
  plugins: [vue()],
  build: {
    target: 'es2018',
    outDir: '../root/www/luci-static/resources/honk/app',
    emptyOutDir: true,
    sourcemap: false,
  },
})
