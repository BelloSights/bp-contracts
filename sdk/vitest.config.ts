import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['**/*.test.ts'],
    globals: true,
    testTimeout: 300000 // Increase timeout to 5 minutes (300,000ms)
  }
})