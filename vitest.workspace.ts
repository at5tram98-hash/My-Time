import { defineWorkspace } from 'vitest/config';

export default defineWorkspace([
  {
    test: {
      name: 'domain',
      include: ['packages/*/src/**/*.test.ts'],
      environment: 'node',
    },
  },
  {
    esbuild: { jsx: 'automatic' },
    test: {
      name: 'web',
      include: ['apps/web/src/**/*.test.{ts,tsx}'],
      environment: 'jsdom',
      setupFiles: ['apps/web/src/test/setup.ts'],
    },
  },
]);
