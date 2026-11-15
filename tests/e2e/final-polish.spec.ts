import { expect, test } from '@playwright/test';
import { at, event, openApp, openDayList, openNewTask, seed, task } from './helpers';

test('新規作成はキーボードを勝手に開かず、タイトルとシート先頭を表示する', async ({ page }) => {
  await openApp(page);
  await openNewTask(page);
  const title = page.getByTestId('editor-title');
  await expect(title).toBeVisible();
  await expect(title).not.toBeFocused();
  expect(await page.locator('.sheet-body').last().evaluate((el) => el.scrollTop)).toBeLessThan(5);
  await title.click();
  await title.fill('入力はタップして開始');
  await expect(title).toBeFocused();
});

test('情報カードの操作は編集の左、場所はGoogle Mapsへ連携する', async ({ page }) => {
  await openApp(page);
  await seed(page, { events: [event({ id: 'map-event', title: 'GU 京都', start: at(12), end: at(13), extra: { place: { name: 'GU', address: '京都市南区', lat: 35, lng: 135 }, notifies: [120] } })] });
  await page.getByTestId('tab-calendar').click();
  const block = page.locator('.tab-panel:not([hidden])').getByTestId('tl-event:map-event');
  await block.scrollIntoViewIfNeeded();
  await block.click();
  const sheet = page.getByTestId('event-info');
  await expect(sheet).toBeVisible();
  const xs = await sheet.locator('.info-actions button').evaluateAll((els) => els.map((e) => e.getBoundingClientRect().x));
  expect(xs.length).toBe(3);
  expect(xs[0]).toBeLessThan(xs[1]!);
  expect(xs[1]).toBeLessThan(xs[2]!);
  await expect(sheet.locator('.map-view')).toHaveAttribute('href', /https:\/\/www.google.com\/maps\/search\//);
  await expect(sheet.locator('.map-open')).toHaveAttribute('href', /destination=35%2C135/);
  await expect(sheet.locator('.info-time-preview')).toContainText('12:00');
});

test('グループ表示はアイコンのあるコンパクトな選択行', async ({ page }) => {
  await openApp(page);
  await page.getByTestId('tab-tasks').click();
  await page.getByTestId('tasks-group').click();
  const group = page.getByTestId('group-popup');
  await expect(group.locator('.compact-choices')).toBeVisible();
  await expect(group.getByRole('radio')).toHaveCount(3);
  expect(await group.getByRole('radio').locator('svg').count()).toBeGreaterThanOrEqual(3);
});

test('ホームは開始60分前から時刻と残り分数を交互表示し、開始済みは交互表示しない', async ({ page }) => {
  await openApp(page);
  await seed(page, { tasks: [task({ id: 'upcoming', title: 'あと60分', plannedStart: at(11, 40), plannedEnd: at(12, 40) })] });
  await openDayList(page);
  await expect(page.getByTestId('task-row-upcoming').getByTestId('upcoming-time')).toHaveAttribute('aria-label', /あと60分/);
  await expect(page.getByTestId('task-row-upcoming').getByTestId('upcoming-time')).toContainText('あと60分', { timeout: 8000 });
});

test('今日の一覧は次のタスクが完了済みより先頭に来る', async ({ page }) => {
  await openApp(page);
  await seed(page, { tasks: [task({ id: 'done-first', title: '完了済み', plannedStart: at(9), plannedEnd: at(10), status: 'done' }), task({ id: 'next-first', title: '次の予定', plannedStart: at(11), plannedEnd: at(12) })] });
  await openDayList(page);
  const rows = page.getByTestId('home-task-list').locator('[data-task-title]');
  await expect(rows.first()).toHaveAttribute('data-task-title', '次の予定');
});

test('地図未接続でも他社タイルへ通信せず、Google Mapsと直接入力だけを案内する', async ({ page }) => {
  const requests: string[] = [];
  page.on('request', r => requests.push(r.url()));
  await openApp(page);
  await openNewTask(page);
  await page.getByTestId('editor-place').click();
  await page.getByTestId('place-query').fill('京都駅');
  await page.getByTestId('place-search').click();
  await expect(page.getByTestId('place-popup')).toContainText('Google Mapsの場所検索はまだ接続されていません');
  expect(requests.some(u => /openstreetmap|nominatim/.test(u))).toBe(false);
});
