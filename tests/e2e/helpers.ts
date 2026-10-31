import { expect, type Locator, type Page } from '@playwright/test';

/** 2026-10-12 (月) 10:40 JST */
export const FIXED_NOW = new Date('2026-10-12T10:40:00+09:00').getTime();
export const HOUR = 3_600_000;
export const MIN = 60_000;
export const DAY0 = new Date('2026-10-12T00:00:00+09:00').getTime();
export const at = (h: number, m = 0, dayOffset = 0) => DAY0 + dayOffset * 24 * HOUR + h * HOUR + m * MIN;

export async function openApp(page: Page, now = FIXED_NOW, opts: { onboarding?: boolean } = {}) {
  await page.clock.setFixedTime(now);
  await page.goto('/');
  await expect(page.getByTestId('home-screen')).toBeVisible();
  if (!opts.onboarding) {
    // 初回セットアップは専用のテストで確認する。ここでは済んだ状態にする
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
    await expect(page.getByTestId('home-screen')).toBeVisible();
    await expect(page.getByTestId('onboarding')).toHaveCount(0);
  }
}

type Rec = Record<string, unknown>;

export function task(fields: Rec): Rec {
  return {
    kind: 'do', special: 'normal', assignment: null, testPrep: null, sourceEventId: null, sourceKey: null, estimateMinutes: null, priority: 0, tags: [],
    flagged: false, notifyMinutesBefore: null, location: null, repeat: null, autoStartAt: null, autoEndAt: null, icon: '📘', calendarId: null, category: null, eventId: null, plannedStart: null, plannedEnd: null,
    timeZone: 'Asia/Tokyo', status: 'notStarted', intervals: [], actualStart: null, actualEnd: null, manualProgress: null,
    pausedEver: false, autoReserved: false, checkAt: null, checked: false, checkedAt: null, notes: '', createdAt: at(0), updatedAt: at(0),
    ...fields,
  };
}

export function event(fields: Rec): Rec {
  return { calendarId: 'cal-general', timeZone: 'Asia/Tokyo', notes: '', recurrence: null, exceptions: [], classInfo: null, employerId: null, hideAfterEnd: false, source: null, createdAt: at(0), updatedAt: at(0), ...fields };
}

/** テスト用データを生の IndexedDB へ直接書き込み、再読み込みする（アプリのコードは使わない） */
export async function seed(page: Page, data: { tasks?: Rec[]; events?: Rec[]; subtasks?: Rec[] }) {
  await page.evaluate(async (d) => {
    const db: IDBDatabase = await new Promise((res, rej) => {
      const r = indexedDB.open('my-time');
      r.onsuccess = () => res(r.result);
      r.onerror = () => rej(r.error);
    });
    await new Promise<void>((res, rej) => {
      const tx = db.transaction(['tasks', 'events', 'subtasks'], 'readwrite');
      for (const t of d.tasks ?? []) tx.objectStore('tasks').put(t);
      for (const e of d.events ?? []) tx.objectStore('events').put(e);
      for (const s of d.subtasks ?? []) tx.objectStore('subtasks').put(s);
      tx.oncomplete = () => res();
      tx.onerror = () => rej(tx.error);
    });
    db.close();
  }, data);
  await page.reload();
  await expect(page.getByTestId('home-screen')).toBeVisible();
}

/** タッチ（指）で要素をドラッグ。CDP の touch イベントを使い、実際のタッチ入力に近づける */
export async function touchDrag(page: Page, from: { x: number; y: number }, to: { x: number; y: number }, opts: { holdMs?: number; steps?: number } = {}) {
  if (page.context().browser()?.browserType().name() !== 'chromium') {
    // WebKit には CDP のタッチ入力がないため、同じ PointerEvent 経路をマウスで操作する
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    if (opts.holdMs) await page.waitForTimeout(opts.holdMs);
    const n = opts.steps ?? 12;
    for (let i = 1; i <= n; i++) await page.mouse.move(from.x + ((to.x - from.x) * i) / n, from.y + ((to.y - from.y) * i) / n);
    await page.mouse.up();
    return;
  }
  const cdp = await page.context().newCDPSession(page);
  const tp = (p: { x: number; y: number }) => [{ x: p.x, y: p.y, id: 1, radiusX: 4, radiusY: 4, force: 1 }];
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: tp(from) });
  if (opts.holdMs) await page.waitForTimeout(opts.holdMs);
  const steps = opts.steps ?? 12;
  for (let i = 1; i <= steps; i++) {
    const p = { x: from.x + ((to.x - from.x) * i) / steps, y: from.y + ((to.y - from.y) * i) / steps };
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: tp(p) });
    await page.waitForTimeout(16);
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await cdp.detach();
}

export async function center(l: Locator) {
  const b = await l.boundingBox();
  if (!b) throw new Error('要素が表示されていません');
  return { x: b.x + b.width / 2, y: b.y + b.height / 2, box: b };
}

/** マウスで長押し→ドラッグ（PointerEvent 経由。タッチとロジックは共通） */
export async function mouseLongPressDrag(page: Page, from: { x: number; y: number }, to: { x: number; y: number }, holdMs = 600, steps = 10) {
  await page.mouse.move(from.x, from.y);
  await page.mouse.down();
  await page.waitForTimeout(holdMs);
  for (let i = 1; i <= steps; i++) {
    await page.mouse.move(from.x + ((to.x - from.x) * i) / steps, from.y + ((to.y - from.y) * i) / steps);
    await page.waitForTimeout(16);
  }
}

/** CDP の生タッチ入力（Chromium のみ）。複数指・touchCancel を再現する */
export async function rawTouch(page: Page) {
  const cdp = await page.context().newCDPSession(page);
  const pts = (ps: { x: number; y: number }[]) => ps.map((p, i) => ({ x: p.x, y: p.y, id: i + 1, radiusX: 4, radiusY: 4, force: 1 }));
  return {
    start: (ps: { x: number; y: number }[]) => cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: pts(ps) }),
    move: (ps: { x: number; y: number }[]) => cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: pts(ps) }),
    end: () => cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] }),
    cancel: () => cdp.send('Input.dispatchTouchEvent', { type: 'touchCancel', touchPoints: [] }),
    detach: () => cdp.detach(),
  };
}

/** 生の IndexedDB から1ストアを読む（アプリのコードを使わない） */
export async function readStore(page: Page, store: string): Promise<Record<string, unknown>[]> {
  return page.evaluate(async (name) => {
    const db: IDBDatabase = await new Promise((res) => {
      const r = indexedDB.open('my-time');
      r.onsuccess = () => res(r.result);
    });
    const rows = await new Promise<Record<string, unknown>[]>((res) => {
      const g = db.transaction(name).objectStore(name).getAll();
      g.onsuccess = () => res(g.result as Record<string, unknown>[]);
    });
    db.close();
    return rows;
  }, store);
}
