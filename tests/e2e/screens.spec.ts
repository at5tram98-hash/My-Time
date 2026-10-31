import { expect, test } from '@playwright/test';
import { at, center, event, mouseLongPressDrag, openApp, seed, task } from './helpers';

/** レビュー用の画面キャプチャ（docs/screenshots に保存）。データはテスト用に投入したもの。 */
const OUT = 'docs/screenshots';

export const demo = {
  tasks: [
    task({ id: 't1', title: '財政学レポート', icon: '📝', category: '課題', calendarId: 'cal-class', plannedStart: at(9), plannedEnd: at(10, 30), status: 'running', intervals: [{ start: at(9, 5), end: null }], actualStart: at(9, 5), manualProgress: { value: 0.6, at: at(10, 20), workedMsAtSample: 75 * 60_000 } }),
    task({ id: 't2', title: 'ミクロ経済 小テスト対策', icon: '📚', category: 'テスト対策', plannedStart: at(10), plannedEnd: at(12) }),
    task({ id: 't3', title: '英語の単語', icon: '✏️', category: '語学', plannedStart: at(8), plannedEnd: at(8, 40), status: 'done', intervals: [{ start: at(8), end: at(8, 35) }], actualStart: at(8), actualEnd: at(8, 35) }),
    task({ id: 't4', title: '持ち物チェック', kind: 'check', icon: '🎒', checkAt: at(12, 30) }),
    task({ id: 't5', title: 'アプリ開発', icon: '💻', category: '個人', plannedStart: at(15), plannedEnd: at(17) }),
    task({ id: 't6', title: 'ゼミ資料の下書き', icon: '💼', category: '課題', plannedStart: at(10, 0, 1), plannedEnd: at(11, 30, 1) }),
    task({ id: 't7', title: '期末試験の範囲確認', icon: '🎯', category: 'テスト対策' }),
  ],
  events: [
    event({ id: 'e1', title: 'マクロ経済学', calendarId: 'cal-class', start: at(10, 45), end: at(12, 15) }),
    event({ id: 'e2', title: 'GU アルバイト', calendarId: 'cal-job', start: at(18), end: at(22) }),
    event({ id: 'e3', title: '昼ごはん', start: at(12, 30), end: at(13, 15) }),
    event({ id: 'e4', title: '歴史学の世界', calendarId: 'cal-class', start: at(13, 15), end: at(14, 45), }),
    event({ id: 'e5', title: '無印良品 夜勤', calendarId: 'cal-job', start: at(22, 0, 1), end: at(6, 0, 2) }),
    event({ id: 'e6', title: 'ゼミ合宿', start: at(9, 0, 4), end: at(17, 0, 8) }),
  ],
};

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
