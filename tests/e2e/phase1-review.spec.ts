import { expect, test, type Page } from '@playwright/test';
import { at, center, event, mouseLongPressDrag, openApp, rawTouch, readStore, seed, task } from './helpers';

/** Phase 1 監査（差し戻し）指摘の回帰テスト */

const eventById = async (page: Page, id: string) => (await readStore(page, 'events')).find((e) => e.id === id);
const taskById = async (page: Page, id: string) => (await readStore(page, 'tasks')).find((t) => t.id === id);
const logCount = async (page: Page) => (await readStore(page, 'operationLog')).length;
/** 時間軸の既定倍率 52px/時 */
const PX_PER_MIN = 52 / 60;

test.describe('1. 予定の重複処理（確認前に保存しない）', () => {
  test.beforeEach(async ({ page }) => {
    await openApp(page);
    await seed(page, {
      events: [
        event({ id: 'A', title: '授業A', calendarId: 'cal-class', start: at(13), end: at(14) }),
        event({ id: 'B', title: '面談B', start: at(15), end: at(16) }),
      ],
    });
    await page.getByTestId('tl-event:B').scrollIntoViewIfNeeded();
  });

  async function dragB(page: Page, minutes: number) {
    const c = await center(page.getByTestId('tl-event:B'));
    await mouseLongPressDrag(page, { x: c.x, y: c.y }, { x: c.x, y: c.y + minutes * PX_PER_MIN });
    await page.mouse.up();
  }

  test('重なる移動はアラートを出し、承認前は保存しない。キャンセルでデータも操作履歴も変わらない', async ({ page }) => {
    const logsBefore = await logCount(page);
    await dragB(page, -90); // 15:00 → 13:30（授業Aと重なる）
    const alert = page.getByRole('alertdialog');
    await expect(alert).toContainText('時間が重なっています');
    await expect(alert).toContainText('授業A');
    // 確認待ちの間は元のデータのまま、仮位置だけを表示
    expect((await eventById(page, 'B'))?.start).toBe(at(15));
    await expect(page.getByTestId('tl-ghost')).toHaveCount(1);
    await alert.getByRole('button', { name: 'キャンセル' }).click();
    await expect(page.getByTestId('tl-ghost')).toHaveCount(0);
    expect((await eventById(page, 'B'))?.start).toBe(at(15));
    expect(await logCount(page)).toBe(logsBefore);
    expect((await eventById(page, 'A'))?.start).toBe(at(13));
  });

  test('提案された空き時間を選ぶとそこへ保存する（既存予定は動かさない）', async ({ page }) => {
    await dragB(page, -90);
    await page.getByRole('alertdialog').getByRole('button', { name: /14:00〜15:00 に移動/ }).click();
    await expect.poll(async () => (await eventById(page, 'B'))?.start).toBe(at(14));
    expect((await eventById(page, 'B'))?.end).toBe(at(15));
    expect((await eventById(page, 'A'))?.start).toBe(at(13));
  });

  test('「重ねて移動」を選んだときだけ重ねて保存する', async ({ page }) => {
    await dragB(page, -90);
    await page.getByRole('alertdialog').getByRole('button', { name: '重ねて移動' }).click();
    await expect.poll(async () => (await eventById(page, 'B'))?.start).toBe(at(13, 30));
  });

  test('重ならない移動は確認なしで15分刻みに保存', async ({ page }) => {
    await dragB(page, 50); // 15:00 → 15:50 → 15:45
    await expect(page.getByRole('alertdialog')).toHaveCount(0);
    await expect.poll(async () => (await eventById(page, 'B'))?.start).toBe(at(15, 45));
  });

  test('新規作成も保存前に確認し、キャンセルなら保存しない', async ({ page }) => {
    await page.getByTestId('home-add').click();
    await page.getByRole('menuitem', { name: '新規予定' }).click();
    await page.getByTestId('event-title-input').fill('打ち合わせ');
    await page.getByTestId('event-start').fill('2026-10-12T13:30');
    await page.getByTestId('event-end').fill('2026-10-12T14:00');
    await page.getByTestId('save-event').click();
    await page.getByRole('alertdialog').getByRole('button', { name: 'キャンセル' }).click();
    await expect(page.getByTestId('event-title-input')).toBeVisible(); // 編集画面に戻る
    expect((await readStore(page, 'events')).length).toBe(2);

    await page.getByTestId('save-event').click();
    await page.getByRole('alertdialog').getByRole('button', { name: /14:00〜14:30 に保存/ }).click();
    await expect(page.getByTestId('event-title-input')).toHaveCount(0);
    const created = (await readStore(page, 'events')).find((e) => e.title === '打ち合わせ');
    expect(created).toMatchObject({ start: at(14), end: at(14, 30) });
  });

  test('編集で時刻を変えたときも保存前に確認する', async ({ page }) => {
    await page.getByTestId('tl-event:B').click();
    await page.getByTestId('event-start').fill('2026-10-12T13:00');
    await page.getByTestId('save-event').click();
    await expect(page.getByRole('alertdialog')).toContainText('授業A');
    await page.getByRole('alertdialog').getByRole('button', { name: 'キャンセル' }).click();
    expect((await eventById(page, 'B'))?.start).toBe(at(15));
  });

  test('タスクの新規作成でも予定との重なりを確認する', async ({ page }) => {
    await page.getByTestId('home-add').click();
    await page.getByRole('menuitem', { name: '新規タスク' }).click();
    await page.getByTestId('task-title-input').fill('レポート');
    await page.getByTestId('task-start').fill('2026-10-12T13:00');
    await page.getByTestId('task-end').fill('2026-10-12T14:00');
    await page.getByTestId('save-task').click();
    await expect(page.getByRole('alertdialog')).toContainText('授業A');
    await page.getByRole('alertdialog').getByRole('button', { name: 'キャンセル' }).click();
    expect((await readStore(page, 'tasks')).length).toBe(0);
  });
});

test.describe('2. 長押し進捗', () => {
  test.beforeEach(async ({ page }) => {
    await openApp(page);
    // 10:00〜12:00、現在10:40 → 理想33%。実績は80%入力済み
    await seed(page, {
      tasks: [task({ id: 'p', title: '進捗', plannedStart: at(10), plannedEnd: at(12), status: 'running', intervals: [{ start: at(10), end: null }], actualStart: at(10), manualProgress: { value: 0.8, at: at(10, 30), workedMsAtSample: 30 * 60_000 } })],
    });
  });

  test('初期値は実績ではなく理想進捗率', async ({ page }) => {
    const c = await center(page.getByTestId('task-row-p'));
    await mouseLongPressDrag(page, { x: c.x, y: c.y }, { x: c.x, y: c.y }, 600, 1);
    await expect(page.getByTestId('progress-scrubber')).toHaveAttribute('aria-valuenow', '33');
    await expect(page.getByTestId('task-row-p')).toHaveClass(/scrubbing/); // セルが浮いている
    await page.mouse.up();
    expect(((await taskById(page, 'p'))?.manualProgress as { value: number }).value).toBe(0.8); // ドラッグなしは変更なし
  });

  test('指の横移動にバーが1:1で追従する', async ({ page }) => {
    const c = await center(page.getByTestId('task-row-p'));
    await mouseLongPressDrag(page, { x: c.x - 100, y: c.y }, { x: c.x - 100, y: c.y }, 600, 1);
    const bar = page.getByTestId('progress-scrubber');
    await page.waitForTimeout(400); // 展開アニメーションの収束
    const w = await bar.evaluate((el) => (el as HTMLElement).getBoundingClientRect().width);
    const v0 = Number(await bar.getAttribute('data-value'));
    for (const frac of [0.1, 0.25, 0.4]) {
      await page.mouse.move(c.x - 100 + w * frac, c.y);
      expect(Number(await bar.getAttribute('data-value'))).toBeCloseTo(v0 + frac, 2);
      const fill = await bar.locator('.scrub-fill').evaluate((el) => (el as HTMLElement).getBoundingClientRect().width);
      expect(Math.abs(fill - (v0 + frac) * w)).toBeLessThan(1.5);
    }
    await page.mouse.up();
    await expect.poll(async () => ((await taskById(page, 'p'))?.manualProgress as { value: number }).value).toBeCloseTo(v0 + 0.4, 2);
  });

  test('タッチの pointercancel では保存しない', async ({ page, browserName }) => {
    test.skip(browserName !== 'chromium', 'CDP のタッチ入力が必要');
    const c = await center(page.getByTestId('task-row-p'));
    const t = await rawTouch(page);
    await t.start([{ x: c.x, y: c.y }]);
    await page.waitForTimeout(600);
    for (let i = 1; i <= 6; i++) await t.move([{ x: c.x + i * 15, y: c.y }]);
    await expect(page.getByTestId('progress-scrubber')).toBeVisible();
    await t.cancel();
    await t.detach();
    await expect(page.getByTestId('progress-scrubber')).toHaveCount(0);
    expect(((await taskById(page, 'p'))?.manualProgress as { value: number }).value).toBe(0.8);
  });
});

test.describe('3. ホーム', () => {
  test('タスク一覧は左右の余白・カードなしで画面幅いっぱい', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 'w', title: '幅', plannedStart: at(11), plannedEnd: at(12) })] });
    const row = (await page.getByTestId('task-row-w').boundingBox())!;
    const vw = page.viewportSize()!.width;
    expect(row.x).toBe(0);
    expect(row.width).toBe(vw);
    const radius = await page.locator('.home .rows').evaluate((el) => getComputedStyle(el).borderTopLeftRadius);
    expect(radius).toBe('0px');
  });

  test('ハンドル操作中の pointercancel では開閉を確定しない', async ({ page, browserName }) => {
    test.skip(browserName !== 'chromium', 'CDP のタッチ入力が必要');
    await openApp(page);
    const h = await center(page.getByTestId('split-handle'));
    const t = await rawTouch(page);
    await t.start([h]);
    for (let i = 1; i <= 10; i++) await t.move([{ x: h.x, y: h.y - i * 30 }]); // 十分に上へ
    await t.cancel();
    await t.detach();
    await page.waitForTimeout(700);
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-expanded', 'false');
    expect((await page.getByTestId('split-handle').boundingBox())!.y).toBeCloseTo(h.box.y, 0);
  });

  test('実行中・次のタスクがなければ拡張時に空のカードを出さない', async ({ page }) => {
    await openApp(page);
    const h = await center(page.getByTestId('split-handle'));
    await mouseLongPressDrag(page, h, { x: h.x, y: h.y - 300 }, 0, 10);
    await page.mouse.up();
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-expanded', 'true');
    await expect(page.locator('[data-testid="floating-cards"] .fcard')).toHaveCount(0);
    await expect(page.getByText('実行中・予定のタスクはありません')).toHaveCount(0);
    await expect.poll(async () => (await page.getByTestId('task-pane').boundingBox())?.height ?? 0).toBeLessThan(2);
  });
});

test.describe('4. カレンダー', () => {
  test('月表示で日付をまたぐ予定を連続したバーで描く（週またぎは両週に続きの印）', async ({ page }) => {
    await openApp(page);
    await seed(page, {
      events: [
        event({ id: 'night', title: '夜勤', calendarId: 'cal-job', start: at(22), end: at(6, 0, 1) }), // 12(月)→13(火)
        event({ id: 'trip', title: 'ゼミ合宿', start: at(9, 0, 4), end: at(17, 0, 8) }), // 16(金)→20(火)
      ],
    });
    await page.getByTestId('tab-calendar').click();
    await page.getByTestId('view-menu').click();
    await page.getByRole('menuitemradio', { name: '月' }).click();
    const night = page.getByTestId('month-bar-night');
    await expect(night).toHaveAttribute('data-span', '2');
    await expect(night).toHaveAttribute('data-col', '1');
    const trip = page.getByTestId('month-bar-trip');
    await expect(trip).toHaveCount(2);
    await expect(trip.nth(0)).toHaveClass(/cont-after/);
    await expect(trip.nth(0)).toHaveAttribute('data-span', '2');
    await expect(trip.nth(1)).toHaveClass(/cont-before/);
    await expect(trip.nth(1)).toHaveAttribute('data-span', '3');
    // バーは月〜火のセルにまたがって1本で描かれる
    const bar = (await night.boundingBox())!;
    const mon = (await page.getByTestId('month-cell-12-in').boundingBox())!;
    const tue = (await page.getByTestId('month-cell-13-in').boundingBox())!;
    expect(bar.x).toBeLessThanOrEqual(mon.x + 3);
    expect(bar.x + bar.width).toBeGreaterThanOrEqual(tue.x + tue.width - 3);
  });

  test('週表示で予定を翌日の列へ移動でき、日付またぎ予定の仮位置は両列に分かれる', async ({ page }) => {
    await openApp(page);
    await seed(page, {
      events: [
        event({ id: 'm', title: '移動', start: at(15), end: at(16) }),
        event({ id: 'n', title: '夜勤', calendarId: 'cal-job', start: at(23), end: at(5, 0, 1) }),
      ],
    });
    await page.getByTestId('tab-calendar').click();
    await page.getByTestId('view-menu').click();
    await page.getByRole('menuitemradio', { name: '週' }).click();
    // 2日→週の切り替えが終わって列幅が落ち着いてから測る（遅い環境で切り替え途中の幅を測ると数日ずれる）
    await expect(page.locator('[data-testid="cal-timeline"] [data-testid="tl-col-6"]')).toBeVisible();
    const colLoc = page.locator('[data-testid="cal-timeline"] [data-testid="tl-col-1"]');
    await expect.poll(async () => {
      const a = (await colLoc.boundingBox())!.width;
      await page.waitForTimeout(150);
      return Math.abs((await colLoc.boundingBox())!.width - a) < 0.5 && a < 393 / 5;
    }).toBe(true);
    const col = (await colLoc.boundingBox())!;
    const block = page.locator('[data-testid="cal-timeline"] [data-testid="tl-event:m"]');
    await block.scrollIntoViewIfNeeded();
    const c = await center(block);
    await mouseLongPressDrag(page, c, { x: c.x + col.width, y: c.y });
    await page.mouse.up();
    await expect.poll(async () => (await eventById(page, 'm'))?.start).toBe(at(15, 0, 1));

    // 夜勤（23:00〜翌5:00）を30分下げる：仮位置は2つの列に分かれて描かれる
    const night = page.locator('[data-testid="cal-timeline"] [data-testid="tl-event:n"]').first();
    await night.scrollIntoViewIfNeeded();
    const nc = await center(night);
    await mouseLongPressDrag(page, nc, { x: nc.x, y: nc.y + 30 * PX_PER_MIN });
    await expect(page.getByTestId('tl-ghost')).toHaveCount(2);
    await page.mouse.up();
    await expect.poll(async () => (await eventById(page, 'n'))?.start).toBe(at(23, 30));
    expect((await eventById(page, 'n'))?.end).toBe(at(5, 30, 1));
  });

  test('カレンダー上のタスクを静止長押ししてもメニューを出さない（タップで詳細）', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 'tt', title: 'タスク長押し', plannedStart: at(14), plannedEnd: at(15) })] });
    const b = page.getByTestId('tl-task:tt');
    await b.scrollIntoViewIfNeeded();
    const c = await center(b);
    await mouseLongPressDrag(page, c, c, 700, 1);
    await page.mouse.up();
    await page.waitForTimeout(300);
    await expect(page.getByRole('dialog')).toHaveCount(0);
    expect((await taskById(page, 'tt'))?.plannedStart).toBe(at(14));
    await b.click();
    await expect(page.getByRole('dialog')).toContainText('タスク長押し');
    await expect(page.getByTestId('delete-task')).toBeVisible();
  });

  test('ピンチは時間軸だけを拡大し、ページ全体はズームしない', async ({ page, browserName }) => {
    test.skip(browserName !== 'chromium', 'CDP の2本指タッチが必要');
    await openApp(page);
    const tl = page.getByTestId('home-timeline');
    const s = await center(page.getByTestId('home-timeline-scroll'));
    const before = Number(await tl.getAttribute('data-hour'));
    const t = await rawTouch(page);
    await t.start([{ x: s.x, y: s.y - 30 }, { x: s.x, y: s.y + 30 }]);
    for (let i = 1; i <= 10; i++) await t.move([{ x: s.x, y: s.y - 30 - i * 8 }, { x: s.x, y: s.y + 30 + i * 8 }]);
    await t.end();
    await t.detach();
    await expect.poll(async () => Number(await tl.getAttribute('data-hour'))).toBeGreaterThan(before * 1.5);
    expect(await page.evaluate(() => window.visualViewport?.scale ?? 1)).toBe(1);
  });
});
