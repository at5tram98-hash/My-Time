import { defineConfig, devices } from '@playwright/test';

/**
 * E2E は iPhone 15 Pro の画面サイズ・タッチ操作を想定。
 * Chromium（モバイル設定・CDPタッチ入力）と WebKit の2つで実行する。
 * 実機 iPhone での確認は別途必要（レポートに「未検証」と明記）。
 */
const iPhone15Pro = {
  viewport: { width: 393, height: 852 },
  screen: { width: 393, height: 852 },
  deviceScaleFactor: 3,
  isMobile: true,
  hasTouch: true,
  userAgent: devices['iPhone 15 Pro']?.userAgent ?? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)',
};

export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 30_000,
  fullyParallel: false,
  workers: 1,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: 'http://localhost:4173',
    locale: 'ja-JP',
    timezoneId: 'Asia/Tokyo',
    trace: 'retain-on-failure',
    serviceWorkers: 'block',
  },
  projects: [
    { name: 'iphone-15-pro', use: { browserName: 'chromium', ...iPhone15Pro } },
    // WebKit（Safari のエンジン）。Linux 版 WebKit は isMobile 非対応のため画面サイズのみ合わせる。
    {
      name: 'webkit',
      testIgnore: /screens.*\.spec/,
      use: { browserName: 'webkit', viewport: iPhone15Pro.viewport, deviceScaleFactor: 3, hasTouch: true },
    },
  ],
  webServer: [{
    command: 'pnpm --filter @my-time/web preview',
    url: 'http://localhost:4173',
    reuseExistingServer: true,
    timeout: 60_000,
  }, {
    command: 'pnpm --filter @my-time/web exec vite preview --host 127.0.0.1 --port 4174 --strictPort',
    url: 'http://127.0.0.1:4174',
    reuseExistingServer: true,
    timeout: 60_000,
  }],
});
