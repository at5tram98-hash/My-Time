import { expect, test, type Locator, type Page } from '@playwright/test';
import { at, openApp, openNewTask, seed, task } from './helpers';

/** v3.1 点検：主要な入力欄に1文字ずつ入力し、値とフォーカスが保たれるか。画面を巡回してエラーが出ないか */
async function typeKeep(page: Page, loc: Locator, text: string) {
  await loc.click();
  await page.keyboard.type(text, { delay: 40 });
  await page.waitForTimeout(500);
  await expect(loc).toBeFocused();
  await expect(loc).toHaveValue(new RegExp(text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
}

test('点検：編集画面のすべての文字入力欄', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await openApp(page);
  await openNewTask(page);
  await typeKeep(page, page.getByTestId('editor-title'), 'テスト');
  await typeKeep(page, page.getByTestId('editor-estimate'), '45');
  await page.getByTestId('editor-place').click();
  await typeKeep(page, page.getByTestId('place-query'), 'kyoto');
  await page.getByTestId('place-manual-toggle').click();
  await typeKeep(page, page.getByTestId('place-name'), '図書館');
  await page.getByTestId('place-popup').getByRole('button', { name: 'キャンセル' }).click();
  await page.getByTestId('editor-tab-option').click();
  await typeKeep(page, page.getByLabel('オンライン会議のURL').or(page.getByLabel(/会議/)).first(), 'https://a.example');
  await typeKeep(page, page.getByTestId('tag-draft'), 'ゼミ');
  await typeKeep(page, page.getByTestId('editor-notes'), 'メモです');
  expect(errors).toEqual([]);
});

test('点検：サブタスク・カレンダー・検索の入力欄', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await openApp(page);
  await seed(page, { tasks: [task({ id: 'a1', title: '点検用', plannedStart: at(14), plannedEnd: at(15) })] });
  await page.getByTestId('task-row-a1').locator('.task-row-main').click();
  await typeKeep(page, page.getByLabel('サブタスク名'), '資料');
  await page.keyboard.press('Escape');
  await page.getByTestId('tab-calendar').click();
  await page.getByTestId('cal-filter').click();
  await page.getByTestId('filter-add-calendar').click();
  await typeKeep(page, page.getByTestId('filter-add-name'), 'バイト');
  await page.keyboard.press('Escape');
  await page.getByTestId('tab-other').click();
  await page.getByTestId('nav-calendars').click();
  await page.getByRole('button', { name: /追加/ }).first().click();
  await typeKeep(page, page.getByTestId('calendar-name'), '新規');
  expect(errors).toEqual([]);
});

test('点検：全タブ巡回でエラーなし', async ({ page }) => {
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource|net::|404/.test(m.text())) errors.push(m.text()); });
  await openApp(page);
  for (const t of ['tab-calendar', 'tab-tasks', 'tab-analysis', 'tab-other', 'tab-home']) {
    await page.getByTestId(t).click();
    await page.waitForTimeout(400);
  }
  expect(errors).toEqual([]);
});
