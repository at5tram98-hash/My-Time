import { test } from '@playwright/test';
import { at, center, event, mouseLongPressDrag, openApp, seed, task } from './helpers';

/** レビュー用の画面キャプチャ（docs/screenshots に保存）。データはテスト用に投入したもの。 */
const OUT = 'docs/screenshots';

export const demo = {
  tasks: [
    task({ id: 't1', title: '財政学レポート', icon: '📝', category: '課題', calendarId: 'cal-class', plannedStart: at(9), plannedEnd: at(10, 30), status: 'running', intervals: [{ start: at(9, 5), end: null }], actualStart: at(9, 5), manualProgress: { value: 0.6, at: at(10, 20), workedMsAtSample: 75 * 60_000 } }),
    task({ id: 't2', title: 'ミクロ経済 小テスト対策', icon: '📚', category: 'テスト対策', plannedStart: at(11), plannedEnd: at(12) }),
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
    await page.waitForTimeout(200);
    await page.screenshot({ path: `${OUT}/03-progress-scrub.png` });
    await page.keyboard.press('Escape');
    await page.mouse.up();
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
