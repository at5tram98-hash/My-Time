import { expect, test, type Page } from '@playwright/test';
import { at, center, openApp, openNewTask, seed, task, touchDrag } from './helpers';
import { demo } from './demo';

/** 指示書 v3 のレビュー用キャプチャ（docs/screenshots/v3）。通常の E2E からは除外（--grep-invert 画面キャプチャ） */
const OUT = 'docs/screenshots/v3';
const shot = async (page: Page, name: string) => { await page.waitForTimeout(500); await page.screenshot({ path: `${OUT}/${name}.png` }); };

for (const scheme of ['light', 'dark'] as const) {
  test(`画面キャプチャ v3（${scheme}）`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: scheme });
    await openApp(page);
    await seed(page, demo);
    await shot(page, `${scheme}-01-home`);
    await page.getByTestId('tab-tasks').click();
    await shot(page, `${scheme}-02-tasks`);
    await page.getByTestId('tab-analysis').click();
    await page.getByTestId('period-week').click();
    await shot(page, `${scheme}-03-analysis-week`);
    await page.getByTestId('analysis-screen').locator('.scroll-body').evaluate((el) => el.scrollTo(0, 900));
    await shot(page, `${scheme}-04-analysis-more`);
    await page.getByTestId('tab-other').click();
    await shot(page, `${scheme}-05-other`);
    await page.getByTestId('nav-calendars').click();
    await shot(page, `${scheme}-06-calendars`);
    await page.getByTestId('back').click();
    await page.getByTestId('nav-appearance').click();
    await shot(page, `${scheme}-07-appearance`);
    await page.getByTestId('back').click();
    await page.getByTestId('tab-home').click();
    await openNewTask(page);
    await page.getByTestId('editor-title').fill('図書館でレポート');
    await shot(page, `${scheme}-08-editor-basic`);
    await page.getByTestId('editor-place').click();
    await page.getByTestId('place-manual-toggle').click();
    await shot(page, `${scheme}-09-place`);
    await page.getByTestId('place-popup').getByRole('button', { name: 'キャンセル' }).click();
    await page.getByTestId('editor-notify').click();
    await shot(page, `${scheme}-10-notify`);
    await page.getByTestId('notify-popup').getByRole('button', { name: 'キャンセル' }).click();
    await page.getByTestId('editor-start-date').click();
    await shot(page, `${scheme}-11-date-wheel`);
    await page.getByTestId('date-picker').getByRole('button', { name: 'キャンセル' }).click();
    await page.getByTestId('editor-tab-option').click();
    await page.getByTestId('tag-draft').fill('#ゼミ #レポート ');
    await shot(page, `${scheme}-12-editor-option`);
    await page.getByRole('button', { name: 'キャンセル' }).first().click();
    await page.getByRole('alertdialog').getByRole('button', { name: '変更を破棄' }).click();
    await page.getByTestId('task-row-t2').locator('.task-row-main').click();
    await expect(page.getByTestId('task-info')).toBeVisible();
    await shot(page, `${scheme}-13-task-info`);
    await page.getByTestId('task-info').locator('.sheet-body, .sheet-scroll').first().evaluate((el) => el.scrollTo(0, 2000)).catch(() => undefined);
    await shot(page, `${scheme}-14-task-info-more`);
  });
}

test('画面キャプチャ v3 コンパクト・狭幅・長押し', async ({ page }) => {
  await openApp(page);
  await seed(page, demo);
  const h = await center(page.getByTestId('split-handle'));
  await touchDrag(page, h, { x: h.x, y: h.y - 400 });
  await shot(page, '15-home-compact');
  await page.setViewportSize({ width: 320, height: 568 });
  await page.getByTestId('tab-tasks').click();
  await shot(page, '16-tasks-320');
  await page.getByTestId('tab-home').click();
  await page.getByRole('button', { name: 'その他の操作' }).click();
  await page.getByRole('menuitem', { name: 'タスク一覧を表示' }).click();
  await page.getByTestId('home-add').click();
  await shot(page, '17-editor-320');
  await page.getByRole('button', { name: 'キャンセル' }).first().click();
  await page.setViewportSize({ width: 393, height: 852 });
  await seed(page, { tasks: [task({ id: 'lp', title: '長押し進捗', plannedStart: at(10), plannedEnd: at(12), status: 'running', intervals: [{ start: at(10), end: null }], actualStart: at(10) })] });
  const c = await center(page.getByTestId('task-row-lp'));
  await page.mouse.move(c.x, c.y);
  await page.mouse.down();
  await page.waitForTimeout(600);
  await page.mouse.move(c.x + 40, c.y);
  await shot(page, '18-longpress-panel');
  await page.mouse.up();
});
