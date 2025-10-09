import { defineConfig } from 'vite';

export default defineConfig({
  server: {
    open: true,
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
});
