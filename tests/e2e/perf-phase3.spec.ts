import { expect, test, type Page } from '@playwright/test';
import { at, event, openApp, seed, task } from './helpers';

/**
 * 性能の測定（画面キャプチャと同様に通常の E2E からは除外：--grep-invert 画面キャプチャ）。
 * 条件：Playwright の Chromium（iPhone 15 Pro の画面サイズ・モバイル設定）、Linux コンテナ、CPU 4倍スロットル。実機の値ではない。
 */
function bigData(nEvents: number, nTasks: number) {
  const events = Array.from({ length: nEvents }, (_, i) => event({ id: `pe${i}`, title: `予定${i}`, start: at(8 + (i % 12), (i % 4) * 15, Math.floor(i / 12) - 60), end: at(9 + (i % 12), (i % 4) * 15, Math.floor(i / 12) - 60) }));
  const tasks = Array.from({ length: nTasks }, (_, i) => task({ id: `pt${i}`, title: `タスク${i}`, plannedStart: at(9 + (i % 10), 0, Math.floor(i / 10) - 60), plannedEnd: at(10 + (i % 10), 0, Math.floor(i / 10) - 60) }));
  return { events, tasks };
}

async function measure(page: Page, label: string) {
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
  const t0 = Date.now();
  await page.reload();
  await expect(page.getByTestId('home-screen')).toBeVisible();
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
  const load = Date.now() - t0;
  const tabs: Record<string, number> = {};
  for (const t of ['calendar', 'tasks', 'analysis', 'other', 'home', 'calendar', 'home'] as const) {
    const s = Date.now();
    await page.getByTestId(`tab-${t}`).click();
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    tabs[t] = Math.max(tabs[t] ?? 0, Date.now() - s);
  }
  // 時間軸の連続スクロール中のフレーム間隔
  const frames = await page.evaluate(async () => {
    const el = document.querySelector('.tab-panel:not([hidden]) .tl-scroll') as HTMLElement;
    const gaps: number[] = [];
    let last = performance.now();
    for (let i = 0; i < 60; i++) {
      el.scrollTop += 12;
      await new Promise((r) => requestAnimationFrame(r));
      const now = performance.now();
      gaps.push(now - last);
      last = now;
    }
    gaps.sort((a, b) => a - b);
    return { p50: Math.round(gaps[30]!), p95: Math.round(gaps[57]!) };
  });
  console.log(`PERF ${label}: 起動 ${load}ms / タブ切替最大 ${JSON.stringify(tabs)} / スクロールのフレーム間隔 p50 ${frames.p50}ms p95 ${frames.p95}ms`);
}

test.describe('画面キャプチャ 性能測定', () => {
  test('通常量と大量データ', async ({ page, browserName }) => {
    test.skip(browserName !== 'chromium', 'CPU スロットルは Chromium のみ');
    test.setTimeout(180_000);
    await openApp(page);
    await seed(page, bigData(60, 40));
    await measure(page, '通常（予定60・タスク40）');
    await seed(page, bigData(3000, 2000));
    await measure(page, '大量（予定3000・タスク2000）');
  });
});
