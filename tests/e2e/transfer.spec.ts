import { readFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { openApp, readStore, seed, task } from './helpers';

test('別Originへの移行：書き出し→件数確認→取込→再起動、元データと同一', async ({ page, browser }, testInfo) => {
  await openApp(page);
  await seed(page, { tasks: [task({ id: 'origin-transfer-task', title: '移行する課題', notes: '元のメモも維持' })] });
  await page.getByTestId('tab-other').click();
  await page.getByTestId('nav-transfer').click();
  const downloadReady = page.waitForEvent('download');
  await page.getByTestId('export-device').click();
  const download = await downloadReady;
  const path = testInfo.outputPath('device-transfer.json');
  await download.saveAs(path);
  const ctx = await browser.newContext({ viewport: { width: 393, height: 852 }, locale: 'ja-JP', serviceWorkers: 'block' });
  const target = await ctx.newPage();
  await target.goto('http://127.0.0.1:4174/');
  await expect(target.getByTestId('home-screen')).toBeVisible();
  // Skip onboarding just as openApp does, keeping this second origin explicit.
  await target.evaluate(async () => {
    const db: IDBDatabase = await new Promise((res) => { const r = indexedDB.open('my-time'); r.onsuccess = () => res(r.result); });
    await new Promise<void>((res) => { const tx = db.transaction('settings', 'readwrite'); const store = tx.objectStore('settings'); const r = store.get('app'); r.onsuccess = () => store.put({ ...r.result, key: 'app', onboarded: true }); tx.oncomplete = () => res(); });
    db.close();
  });
  await target.reload();
  await target.getByTestId('tab-other').click();
  await target.getByTestId('nav-transfer').click();
  await target.getByLabel('移行ファイル', { exact: true }).setInputFiles({ name: 'device-transfer.json', mimeType: 'application/json', buffer: readFileSync(path) }); // パスに日本語を含む環境でも確実に渡す
  await target.getByTestId('import-device').click();
  await expect(target.getByRole('alertdialog')).toBeVisible();
  await target.getByRole('button', { name: '取り込む', exact: true }).click();
  await expect.poll(async () => (await readStore(target, 'tasks')).length).toBe(1);
  expect(await readStore(target, 'tasks')).toEqual(await readStore(page, 'tasks'));
  await target.reload();
  expect((await readStore(target, 'tasks'))[0]?.notes).toBe('元のメモも維持');
  expect((await readStore(page, 'tasks')).length).toBe(1);
  await ctx.close();
});
