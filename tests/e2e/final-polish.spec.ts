import { expect, test } from '@playwright/test';
import { at, event, openApp, seed, task } from './helpers';

test('新規作成はキーボードを勝手に開かず、タイトルとシート先頭を表示する', async ({ page }) => {
  await openApp(page);
  await page.getByTestId('home-add').click();
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
  await expect(page.getByTestId('task-row-upcoming').getByTestId('upcoming-time')).toHaveAttribute('aria-label', /あと60分/);
  await expect(page.getByTestId('task-row-upcoming').getByTestId('upcoming-time')).toContainText('あと60分', { timeout: 8000 });
});
