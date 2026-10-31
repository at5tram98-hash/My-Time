import { defineConfig } from '@playwright/test';

/**
 * サーバー連携の E2E。ローカルの Worker（web/dist + API を同一オリジンで配信）と模擬 Google を起動して、
 * ログイン → 同期 → 22時バックアップ → 期限削除 → 期間指定復元 を実際の画面とHTTPで確認する。
 * 本物の Google・Cloudflare には接続しない（値はすべてテスト用ダミー）。
 */
export default defineConfig({
  testDir: 'tests/stack',
  timeout: 90_000,
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: 'http://localhost:8787',
    locale: 'ja-JP',
    timezoneId: 'Asia/Tokyo',
    viewport: { width: 393, height: 852 },
    deviceScaleFactor: 3,
    hasTouch: true,
    serviceWorkers: 'block',
    trace: 'retain-on-failure',
  },
  projects: [
    { name: 'stack-chromium', use: { browserName: 'chromium', isMobile: true } },
    { name: 'stack-webkit', use: { browserName: 'webkit' } },
  ],
  webServer: {
    command: 'bash tests/fake-google/start-stack.sh',
    url: 'http://localhost:8787/api/config',
    reuseExistingServer: false,
    timeout: 120_000,
  },
});
