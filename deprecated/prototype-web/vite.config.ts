import { defineConfig } from 'vite';

export default defineConfig({
  // Relative asset URLs so dist/index.html also works when Electron loads it from a file:// URL.
  base: './',
  server: {
    port: 5173,
    strictPort: true,
    // electron-builder writes into release/ while the dev server runs; watching it crashes Vite on Windows.
    watch: { ignored: ['**/release/**', '**/dist/**', '**/node_modules/**'] },
  },
  build: {
    outDir: 'dist',
  },
});
