import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

// GitHub Pages では /my-time/ 配下で配信する（BASE_PATH で切替）
const base = process.env.BASE_PATH ?? '/';

export default defineConfig({
  base,
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      injectRegister: 'auto',
      // 独自の Service Worker（Push 通知の受信、API はキャッシュしない）
      strategies: 'injectManifest',
      srcDir: 'src',
      filename: 'sw.ts',
      injectManifest: { globPatterns: ['**/*.{js,css,html,svg,png,woff2}'] },
      includeAssets: ['icon.svg', 'apple-touch-icon.png'],
      manifest: {
        name: 'My Time',
        short_name: 'My Time',
        description: '予定とタスクの時間管理',
        lang: 'ja',
        start_url: base,
        scope: base,
        display: 'standalone',
        orientation: 'portrait',
        background_color: '#F2F2F7',
        theme_color: '#F2F2F7',
        // ホーム画面のアイコンを長押ししたときの近道（P44。対応する端末だけ。iOS では表示されないことがある）
        shortcuts: [
          { name: '追加', short_name: '追加', url: `${base}?action=add`, icons: [{ src: 'icon-192.png', sizes: '192x192' }] },
          { name: '未割当', short_name: '未割当', url: `${base}?action=inbox`, icons: [{ src: 'icon-192.png', sizes: '192x192' }] },
          { name: 'タスク', short_name: 'タスク', url: `${base}?tab=tasks`, icons: [{ src: 'icon-192.png', sizes: '192x192' }] },
        ],
        icons: [
          { src: 'icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: 'icon-512.png', sizes: '512x512', type: 'image/png' },
          { src: 'icon-512-maskable.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
    }),
  ],
  build: {
    rollupOptions: {
      output: {
        manualChunks: { react: ['react', 'react-dom'], motion: ['motion'], data: ['dexie', 'dexie-react-hooks'] },
      },
    },
  },
  server: { host: true, port: 5173 },
  preview: { host: true, port: 4173 },
});
