import { defineConfig } from 'vite';

const releasePath = (process.env.VITE_CAPGO_APP_LABEL ?? 'bundle').replace(/[^a-zA-Z0-9-_]/g, '-');

export default defineConfig({
  server: {
    open: true,
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: `assets/${releasePath}/[name].js`,
        chunkFileNames: `assets/${releasePath}/[name].js`,
        assetFileNames: `assets/${releasePath}/[name][extname]`,
      },
    },
  },
});
