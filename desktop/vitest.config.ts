import { resolve } from 'node:path'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  resolve: {
    alias: {
      '@shared': resolve(__dirname, 'src/shared'),
      '@': resolve(__dirname, 'src/renderer/src'),
    },
  },
  test: {
    // Everything under test is pure logic or filesystem code; nothing needs a DOM.
    environment: 'node',
    include: ['src/**/*.test.ts'],
  },
})
