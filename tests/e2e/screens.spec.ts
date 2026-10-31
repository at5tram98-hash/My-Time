import { expect, test } from '@playwright/test';
import { center, mouseLongPressDrag, openApp, seed } from './helpers';
import { demo } from './demo';

/** レビュー用の画面キャプチャ（docs/screenshots に保存）。データはテスト用に投入したもの。 */
const OUT = 'docs/screenshots';

test.describe('画面キャプチャ', () => {
  test('ライト', async ({ page }) => {
    await openApp(page);
    await seed(page, demo);
    await page.waitForTimeout(500);
    await page.screenshot({ path: `${OUT}/01-home-1day.png` });

    await page.getByTestId('days-toggle').click();
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${OUT}/02-home-2day.png` });
    await page.getByTestId('days-toggle').click();

    // 長押しスライド中の進捗カプセル
    const row = page.getByTestId('task-row-t2');
    const c = await center(row);
    await mouseLongPressDrag(page, { x: c.box.x + 60, y: c.y }, { x: c.box.x + 160, y: c.y });
    await page.waitForTimeout(350);
    await page.screenshot({ path: `${OUT}/03-progress-scrub.png` });
    await page.mouse.up();
    await page.waitForTimeout(400);

    // 予定を重なる時間へドラッグ → 保存前の確認アラート（キャンセル）
    const lunch = page.getByTestId('tl-event:e3');
    await lunch.scrollIntoViewIfNeeded();
    const lc = await center(lunch);
    await mouseLongPressDrag(page, lc, { x: lc.x, y: lc.y - 60 * (52 / 60) });
    await page.mouse.up();
    // 固定時刻（clock）下では表示アニメーションの開始が遅れるため、表示完了を待つ
    await expect.poll(() => page.getByRole('alertdialog').evaluate((el) => getComputedStyle(el).opacity)).toBe('1');
    await page.screenshot({ path: `${OUT}/15-conflict-alert.png` });
    await page.getByRole('alertdialog').getByRole('button', { name: 'キャンセル' }).click();
    await page.waitForTimeout(400);

    // 境界ハンドルを上へドラッグしてカレンダー拡張
    const h = await center(page.getByTestId('split-handle'));
    await page.mouse.move(h.x, h.y);
    await page.mouse.down();
    for (let i = 1; i <= 10; i++) await page.mouse.move(h.x, h.y - i * 30);
    await page.mouse.up();
    await page.waitForTimeout(700);
    await page.screenshot({ path: `${OUT}/04-home-expanded.png` });

    await page.getByTestId('fcard-running').click();
    await page.waitForTimeout(600);
    await page.screenshot({ path: `${OUT}/05-task-detail.png` });
    await page.keyboard.press('Escape');
    await page.waitForTimeout(400);

    await page.getByTestId('tab-calendar').click();
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${OUT}/06-calendar-2day.png` });
    await page.getByTestId('view-menu').click();
    await page.getByRole('menuitemradio', { name: '週' }).click();
    await page.waitForTimeout(900);
    await page.screenshot({ path: `${OUT}/07-calendar-week.png` });
    await page.getByTestId('view-menu').click();
    await page.getByRole('menuitemradio', { name: '月' }).click();
    await page.waitForTimeout(900);
    await page.screenshot({ path: `${OUT}/08-calendar-month.png` });

    await page.getByTestId('tab-tasks').click();
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${OUT}/09-tasks.png` });

    await page.getByTestId('tab-analysis').click();
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${OUT}/10-analysis.png` });

    await page.getByTestId('tab-other').click();
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${OUT}/11-other.png` });
  });

  test('ダーク', async ({ page }) => {
    await page.emulateMedia({ colorScheme: 'dark' });
    await openApp(page);
    await seed(page, demo);
    await page.waitForTimeout(500);
    await page.screenshot({ path: `${OUT}/12-home-dark.png` });
    await page.getByTestId('tab-calendar').click();
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${OUT}/13-calendar-dark.png` });
  });

  test('新規作成シート', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('home-add').click();
    await page.getByRole('menuitem', { name: '新規タスク' }).click();
    await page.waitForTimeout(600);
    await page.screenshot({ path: `${OUT}/14-new-task.png` });
  });
});

test('画面キャプチャ：操作録画', async ({ browser }) => {
  test.setTimeout(90_000);
  const context = await browser.newContext({
    viewport: { width: 393, height: 852 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, locale: 'ja-JP', timezoneId: 'Asia/Tokyo',
    serviceWorkers: 'block', recordVideo: { dir: 'test-results/video', size: { width: 393, height: 852 } },
  });
  const page = await context.newPage();
  await openApp(page);
  await seed(page, demo);
  await page.waitForTimeout(800);
  const slow = async (from: { x: number; y: number }, to: { x: number; y: number }, hold: number, steps: number) => {
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    await page.waitForTimeout(hold);
    for (let i = 1; i <= steps; i++) {
      await page.mouse.move(from.x + ((to.x - from.x) * i) / steps, from.y + ((to.y - from.y) * i) / steps);
      await page.waitForTimeout(24);
    }
    await page.waitForTimeout(250);
    await page.mouse.up();
  };
  // 長押し → 横スライドで進捗
  const r = await center(page.getByTestId('task-row-t2'));
  await slow({ x: r.box.x + 80, y: r.y }, { x: r.box.x + 200, y: r.y }, 650, 30);
  await page.waitForTimeout(700);
  // 境界ハンドルで拡張 → 戻す
  const h = await center(page.getByTestId('split-handle'));
  await slow(h, { x: h.x, y: h.y - 320 }, 0, 25);
  await page.waitForTimeout(1000);
  const h2 = await center(page.getByTestId('split-handle'));
  await slow(h2, { x: h2.x, y: h2.y + 320 }, 0, 25);
  await page.waitForTimeout(800);
  // 予定を重なる時間へ → 提案された空き時間を選ぶ
  const lunch = page.getByTestId('tl-event:e3');
  await lunch.scrollIntoViewIfNeeded();
  const lc = await center(lunch);
  await slow(lc, { x: lc.x, y: lc.y - 52 }, 650, 20);
  await expect.poll(() => page.getByRole('alertdialog').evaluate((el) => getComputedStyle(el).opacity)).toBe('1');
  await page.waitForTimeout(1000);
  await page.getByRole('alertdialog').getByRole('button', { name: /に移動$/ }).first().click();
  await page.waitForTimeout(1200);
  // 月表示（日付またぎの連続バー）
  await page.getByTestId('tab-calendar').click();
  await page.getByTestId('view-menu').click();
  await page.waitForTimeout(400);
  await page.getByRole('menuitemradio', { name: '月' }).click();
  await page.waitForTimeout(1500);
  await context.close();
  const v = page.video();
  if (v) await v.saveAs(`${OUT}/../media/phase1-demo.webm`);
});
