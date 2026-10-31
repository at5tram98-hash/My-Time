import { expect, test, type Browser, type Page } from '@playwright/test';

/**
 * 同期とデータ保護ゲートの通し確認（ローカル Worker + 模擬 Google）。
 * - バックアップが失敗した日は、期限が来たデータでも消さない
 * - 読み戻し確認できたバックアップ＋アーカイブがある時だけ期限削除する
 * - 期間指定復元で戻り、「閲覧を終了」で外れても Drive の保管データは残る
 */
const FAKE = 'http://localhost:9876';
const DAY = 86_400_000;

async function fake(path: string, body: unknown = {}) {
  const r = await fetch(`${FAKE}${path}`, { method: 'POST', body: JSON.stringify(body) });
  return r.json();
}

async function runCron() {
  // wrangler dev --test-scheduled：22時（JST）のバックアップ→期限処理を今すぐ実行
  await fetch('http://localhost:8787/__scheduled?cron=0+13+*+*+*');
}

async function login(browser: Browser) {
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await page.goto('/');
  await skipOnboarding(page);
  await page.getByTestId('tab-other').click();
  await page.getByTestId('login').click();
  await page.waitForURL(/login=ok/);
  // 初回は「ログインしていない間の領域」から、このアカウントの領域へ切り替わる（再読み込み）
  await expect.poll(() => page.evaluate(() => localStorage.getItem('mytime:activeDb')).catch(() => ''), { timeout: 15_000 }).toMatch(/^my-time@/);
  await page.waitForLoadState('load');
  await expect(page.getByTestId('home-screen')).toBeVisible();
  await page.getByTestId('tab-other').click();
  await expect(page.getByTestId('account-row')).toContainText('yuki', { timeout: 15_000 });
  return page;
}

async function skipOnboarding(page: Page) {
  await expect(page.getByTestId('home-screen')).toBeVisible();
  await page.evaluate(async () => {
    const db: IDBDatabase = await new Promise((res) => {
      const r = indexedDB.open('my-time');
      r.onsuccess = () => res(r.result);
    });
    await new Promise<void>((res) => {
      const tx = db.transaction('settings', 'readwrite');
      const st = tx.objectStore('settings');
      const g = st.get('app');
      g.onsuccess = () => st.put({ ...(g.result ?? {}), key: 'app', onboarded: true });
      tx.oncomplete = () => res();
    });
    db.close();
  });
  await page.reload();
  await expect(page.getByTestId('onboarding')).toHaveCount(0);
}

/** 領域の切り替え直後は再読み込みが入るので、読み取りに失敗したら少し待って読み直す */
async function taskTitles(page: Page): Promise<string[]> {
  for (let i = 0; ; i++) {
    try {
      await page.waitForLoadState('load');
      return await readTitles(page);
    } catch (e) {
      if (i >= 10 || !String(e).includes('Execution context was destroyed')) throw e;
      await page.waitForTimeout(300);
    }
  }
}

async function readTitles(page: Page): Promise<string[]> {
  return page.evaluate(async () => {
    // 表示中の保存領域（ログイン中はアカウントごとの領域）
    const name = localStorage.getItem('mytime:activeDb') ?? 'my-time';
    const db: IDBDatabase = await new Promise((res) => {
      const r = indexedDB.open(name);
      r.onsuccess = () => res(r.result);
    });
    const rows = await new Promise<{ title: string }[]>((res) => {
      const g = db.transaction('tasks').objectStore('tasks').getAll();
      g.onsuccess = () => res(g.result as { title: string }[]);
    });
    db.close();
    return rows.map((r) => r.title).sort();
  });
}

async function syncNow(page: Page) {
  await page.getByTestId('tab-other').click();
  if (await page.getByTestId('back').isVisible()) await page.getByTestId('back').click();
  await page.getByTestId('sync-row').click();
  await expect(page.getByTestId('sync-status')).toHaveText(/同期済み|最新/, { timeout: 20_000 });
}

/** アプリの操作でタスクを作る（作成画面から） */
async function addTask(page: Page, title: string, start: string, end: string) {
  await page.getByTestId('tab-tasks').click();
  await page.getByRole('button', { name: 'その他の操作' }).click();
  await page.getByRole('menuitem', { name: '新規タスク' }).click();
  await page.getByTestId('task-title-input').fill(title);
  await page.getByTestId('task-start').fill(start);
  await page.getByTestId('task-end').fill(end);
  await page.getByTestId('save-task').click();
  const alert = page.getByRole('alertdialog');
  if (await alert.isVisible().catch(() => false)) await alert.getByRole('button', { name: '重ねて保存' }).click();
  await expect(page.getByTestId('task-title-input')).toHaveCount(0);
}

test('ログイン→2台目へ同期→バックアップ失敗日は削除しない→検証後だけ期限削除→期間指定復元→閲覧終了', async ({ browser }, info) => {
  await fake('/__reset');
  await fake('/__user', { sub: `e2e-${info.project.name}`, email: `yuki+${info.project.name}@example.com`, name: 'ゆうき' });

  const now = Date.now();
  const old = new Date(now - 45 * DAY);
  const ymd = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const today = new Date(now);

  // 1台目：ログインして、45日前のタスクと今日のタスクを作る
  const a = await login(browser);
  await addTask(a, '古いレポート', `${ymd(old)}T10:00`, `${ymd(old)}T11:00`);
  await addTask(a, '今日の課題', `${ymd(today)}T23:00`, `${ymd(today)}T23:30`);
  await syncNow(a);

  // 2台目：同じアカウントでログインすると同期される
  const b = await login(browser);
  await expect.poll(() => taskTitles(b), { timeout: 20_000 }).toEqual(['今日の課題', '古いレポート']);

  // バックアップの保存に失敗する日：期限切れでも削除しない
  await fake('/__fail', { upload: true });
  await runCron();
  await expect.poll(async () => (await (await a.request.get('/api/backups', { headers: { 'x-mytime': '1' } })).json()).items.length, { timeout: 20_000 }).toBeGreaterThan(0);
  const failed = (await (await a.request.get('/api/backups')).json()).items;
  expect(failed.every((x: { status: string }) => x.status !== 'verified')).toBe(true);
  await syncNow(a);
  expect(await taskTitles(a)).toEqual(['今日の課題', '古いレポート']);
  await a.getByTestId('tab-other').click();
  await expect(a.getByTestId('other-alert')).toBeVisible(); // 「!」で知らせる

  // 読み戻しで壊れていたら成功扱いにしない
  await fake('/__fail', { corruptDownload: true });
  await runCron();
  await a.waitForTimeout(1500);
  await syncNow(a);
  expect(await taskTitles(a)).toEqual(['今日の課題', '古いレポート']);

  // 正常な日：検証済みバックアップ＋アーカイブ確認後に、期限切れ（45日前）だけ削除
  await fake('/__fail', {});
  await runCron();
  await expect.poll(async () => (await (await a.request.get('/api/backups')).json()).items.filter((x: { status: string; kind: string }) => x.status === 'verified').map((x: { kind: string }) => x.kind).sort(), { timeout: 20_000 }).toEqual(['archive', 'daily']);
  await syncNow(a);
  await expect.poll(() => taskTitles(a)).toEqual(['今日の課題']);
  await syncNow(b);
  await expect.poll(() => taskTitles(b)).toEqual(['今日の課題']);
  const files = (await (await fetch(`${FAKE}/__files`)).json()) as { name: string }[];
  expect(files.some((f) => /archive/i.test(f.name))).toBe(true);

  // 同じ日にもう一度実行しても何も起きない（冪等）
  await runCron();
  await a.waitForTimeout(1500);
  await syncNow(a);
  expect(await taskTitles(a)).toEqual(['今日の課題']);

  // 期間指定復元：45日前を含む期間 → 戻って表示、バナーが出る
  await a.getByTestId('tab-other').click();
  await a.getByTestId('nav-restore').click();
  await a.getByTestId('restore-from').fill(ymd(new Date(now - 50 * DAY)));
  await a.getByTestId('restore-to').fill(ymd(new Date(now - 40 * DAY)));
  await a.getByTestId('run-restore').click();
  await expect.poll(() => taskTitles(a), { timeout: 20_000 }).toEqual(['今日の課題', '古いレポート']);
  await expect(a.getByTestId('restore-banner')).toContainText('1件');
  if (info.project.name === 'stack-chromium') {
    await a.getByTestId('tab-tasks').click();
    await a.waitForTimeout(3500); // 案内のトーストが消えてから
    await a.screenshot({ path: 'docs/screenshots/p2-13-restore-banner.png' });
  }

  // 復元中は期限処理で再び消さない
  await runCron();
  await a.waitForTimeout(1500);
  await syncNow(a);
  expect(await taskTitles(a)).toEqual(['今日の課題', '古いレポート']);

  // 閲覧を終了 → 通常画面から外れるが、Drive の保管データは残る
  await a.getByTestId('banner-end-restore').click();
  await a.getByRole('alertdialog').getByRole('button', { name: '閲覧を終了' }).click();
  await expect.poll(() => taskTitles(a), { timeout: 20_000 }).toEqual(['今日の課題']);
  await expect(a.getByTestId('restore-banner')).toHaveCount(0);
  if (info.project.name === 'stack-chromium') {
    await a.getByTestId('tab-other').click();
    if (await a.getByTestId('back').isVisible()) await a.getByTestId('back').click();
    await a.waitForTimeout(400);
    await a.screenshot({ path: 'docs/screenshots/p2-10-other-loggedin.png' });
    await a.getByTestId('nav-backups').click();
    await expect(a.getByTestId('backup-row').first()).toBeVisible();
    await a.waitForTimeout(400);
    await a.screenshot({ path: 'docs/screenshots/p2-11-backups.png' });
    await a.getByTestId('back').click();
    await a.getByTestId('nav-notices').click();
    await a.waitForTimeout(400);
    await a.screenshot({ path: 'docs/screenshots/p2-12-notices.png' });
  }
  const after = (await (await fetch(`${FAKE}/__files`)).json()) as { name: string }[];
  expect(after.filter((f) => /archive/i.test(f.name)).length).toBe(files.filter((f) => /archive/i.test(f.name)).length);
});

/** すでに開いているページで（同じブラウザのまま）Google ログインする */
async function loginOnPage(page: Page) {
  await page.getByTestId('tab-other').click();
  if (await page.getByTestId('back').isVisible()) await page.getByTestId('back').click();
  await page.getByTestId('login').click();
  await page.waitForURL(/login=ok/);
}

/** 表示中の保存領域。切り替え直後の再読み込み中は読めないので空文字を返し、expect.poll で待つ */
const activeArea = (page: Page) => page.evaluate(() => localStorage.getItem('mytime:activeDb') ?? 'my-time').catch(() => '');

test('アカウントごとの保存領域：ログイン前のデータは確認してから移す／ログアウト／別アカウントには混ざらない', async ({ browser }, info) => {
  await fake('/__reset');
  const tag = info.project.name;
  await fake('/__user', { sub: `acct-a-${tag}`, email: `a-${tag}@example.com`, name: 'A' });
  const ctx = await browser.newContext();
  const page = await ctx.newPage();
  await page.goto('/');
  await skipOnboarding(page);
  const today = new Date();
  const ymd = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;

  // ログインせずに作ったデータ
  await addTask(page, 'ログイン前のメモ', `${ymd}T21:00`, `${ymd}T21:30`);
  expect(await activeArea(page)).toBe('my-time');

  // Aでログイン → 件数と移行先を示して確認。選ぶまで何も送らない
  await loginOnPage(page);
  const dlg = page.getByTestId('account-choice');
  await expect(dlg).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('ac-counts')).toContainText('タスク1件');
  await expect(page.getByTestId('ac-target')).toHaveText(`a-${tag}@example.com`);
  if (tag === 'stack-chromium') await page.screenshot({ path: 'docs/screenshots/p2-14-account-migrate.png' });
  const serverBefore = await (await page.request.get('/api/sync/pull?cursor=0')).json();
  expect(serverBefore.changes).toHaveLength(0);
  await page.getByTestId('ac-migrate').click();
  await expect.poll(() => activeArea(page), { timeout: 15_000 }).toMatch(/^my-time@/);
  await expect(page.getByTestId('home-screen')).toBeVisible();
  await expect.poll(async () => (await (await page.request.get('/api/sync/pull?cursor=0')).json()).changes.map((c: { record: { title?: string } | null }) => c.record?.title), { timeout: 20_000 }).toContain('ログイン前のメモ');
  expect(await taskTitles(page)).toEqual(['ログイン前のメモ']);

  // ログアウト → ログインしていない領域（移したので空）に戻る
  await page.getByTestId('tab-other').click();
  await page.getByTestId('logout').click();
  await expect.poll(() => activeArea(page), { timeout: 15_000 }).toBe('my-time');
  await expect(page.getByTestId('home-screen')).toBeVisible();
  expect(await taskTitles(page)).toEqual([]);

  // 同じブラウザで別のアカウント B にログイン → A のデータは表示も送信もされない
  await fake('/__user', { sub: `acct-b-${tag}`, email: `b-${tag}@example.com`, name: 'B' });
  await loginOnPage(page);
  await expect.poll(() => activeArea(page), { timeout: 15_000 }).toMatch(/^my-time@/);
  const areaB = await activeArea(page);
  await expect(page.getByTestId('home-screen')).toBeVisible();
  await syncNow(page);
  expect(await taskTitles(page)).toEqual([]);
  expect((await (await page.request.get('/api/sync/pull?cursor=0')).json()).changes).toHaveLength(0);

  // A で入り直すと、A のデータが戻る（B の領域とは別）
  await page.getByTestId('tab-other').click();
  await page.getByTestId('logout').click();
  await expect.poll(() => activeArea(page), { timeout: 15_000 }).toBe('my-time');
  await fake('/__user', { sub: `acct-a-${tag}`, email: `a-${tag}@example.com`, name: 'A' });
  await loginOnPage(page);
  await expect.poll(() => activeArea(page), { timeout: 15_000 }).toMatch(/^my-time@/);
  expect(await activeArea(page)).not.toBe(areaB);
  await expect.poll(() => taskTitles(page), { timeout: 20_000 }).toEqual(['ログイン前のメモ']);
  await ctx.close();
});

test('ログイン CSRF：ログインを始めていないブラウザで callback を開いてもログインされない', async ({ browser }) => {
  await fake('/__reset');
  await fake('/__user', { sub: 'csrf-attacker', email: 'attacker@example.com', name: 'X' });
  // 攻撃者のブラウザで同意まで進め、callback URL を取り出す（リダイレクトを追わない）
  const attacker = await browser.newContext();
  const start = await attacker.request.get('/api/auth/login', { maxRedirects: 0 });
  const google = await attacker.request.get(start.headers()['location']!, { maxRedirects: 0 });
  const callbackUrl = google.headers()['location']!;
  // 被害者のブラウザで開かせる
  const victim = await browser.newContext();
  const page = await victim.newPage();
  await page.goto('/');
  await skipOnboarding(page);
  await page.goto(callbackUrl);
  await page.waitForURL(/login=error/);
  const cookies = await victim.cookies();
  expect(cookies.some((c) => c.name === 'mt_session')).toBe(false);
  expect((await page.request.get('/api/me')).status()).toBe(401);
  await attacker.close();
  await victim.close();
});
