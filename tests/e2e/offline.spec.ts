import { expect, test } from '@playwright/test';
import { at, openApp, seed, task } from './helpers';

test.use({ serviceWorkers: 'allow' });

test('Service Worker 登録後はオフラインで再起動でき、端末内データも残る', async ({ page, context, browserName }) => {
  test.skip(browserName === 'webkit', 'Playwright の Linux 版 WebKit はオフライン時の再読み込みで内部エラーになるため対象外（実機で確認が必要）');
  await openApp(page);
  await page.evaluate(async () => {
    await navigator.serviceWorker.ready;
  });
  await page.reload(); // SW の管理下でページを開き直す
  await expect.poll(() => page.evaluate(() => !!navigator.serviceWorker.controller)).toBe(true);
  await seed(page, { tasks: [task({ id: 'off', title: 'オフライン確認', plannedStart: at(15), plannedEnd: at(16) })] });
  await context.setOffline(true);
  await page.reload();
  await expect(page.getByTestId('home-screen')).toBeVisible();
  await expect(page.getByTestId('task-row-off')).toBeVisible();
  // オフラインのまま編集（タスク開始）→ 再読み込みしても残る
  await page.getByTestId('task-row-off').locator('.task-row-main').click();
  await page.getByTestId('task-actions').getByRole('button', { name: '開始' }).click();
  await expect(page.getByTestId('task-actions').getByRole('button', { name: '一時停止' })).toBeVisible();
  await page.reload();
  await expect(page.getByTestId('task-row-off')).toContainText('実行中');
  await context.setOffline(false);
});
