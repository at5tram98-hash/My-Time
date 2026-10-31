import { expect, test, type Page } from '@playwright/test';
import { at, center, event, FIXED_NOW, mouseLongPressDrag, openApp, seed, task, touchDrag } from './helpers';

const readTask = (page: Page, id: string) =>
  page.evaluate(async (tid) => {
    const db: IDBDatabase = await new Promise((res) => {
      const r = indexedDB.open('my-time');
      r.onsuccess = () => res(r.result);
    });
    const v = await new Promise<Record<string, unknown> | undefined>((res) => {
      const g = db.transaction('tasks').objectStore('tasks').get(tid);
      g.onsuccess = () => res(g.result as Record<string, unknown> | undefined);
    });
    db.close();
    return v;
  }, id);

const readEvent = (page: Page, id: string) =>
  page.evaluate(async (eid) => {
    const db: IDBDatabase = await new Promise((res) => {
      const r = indexedDB.open('my-time');
      r.onsuccess = () => res(r.result);
    });
    const v = await new Promise<Record<string, unknown> | undefined>((res) => {
      const g = db.transaction('events').objectStore('events').get(eid);
      g.onsuccess = () => res(g.result as Record<string, unknown> | undefined);
    });
    db.close();
    return v;
  }, id);

test.describe('ナビゲーションと表示', () => {
  test('5タブが動作し、日付はホーム上部の1箇所だけ', async ({ page }) => {
    await openApp(page);
    await expect(page.getByTestId('home-date')).toHaveText('12日(月)');
    await expect(page.getByText('12日(月)', { exact: true })).toHaveCount(1);
    // 1日表示ではタイムラインに日付見出しを出さない
    await expect(page.locator('[data-testid="home-timeline"] .tl-head')).toHaveCount(0);
    for (const t of ['calendar', 'tasks', 'analysis', 'other', 'home'] as const) {
      await page.getByTestId(`tab-${t}`).click();
      await expect(page.getByTestId(`tab-${t}`)).toHaveAttribute('aria-current', 'page');
    }
  });

  test('ホームは1日⇔2日をアイコンで切替（2日表示は右側の日付だけ表示）', async ({ page }) => {
    await openApp(page);
    const cols = page.locator('[data-testid="home-timeline"] .tl-col');
    await expect(cols).toHaveCount(1);
    await page.getByTestId('days-toggle').click();
    await expect(cols).toHaveCount(2);
    await expect(page.locator('[data-testid="home-timeline"] .tl-day-label:not(.hidden)')).toHaveCount(1);
    await page.getByTestId('days-toggle').click();
    await expect(cols).toHaveCount(1);
  });

  test('カレンダータブは初期2日、日/週/月に切替できる', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('tab-calendar').click();
    await expect(page.getByTestId('calendar-screen')).toHaveAttribute('data-view', '2day');
    await expect(page.locator('[data-testid="cal-timeline"] .tl-col')).toHaveCount(2);
    await page.getByTestId('view-menu').click();
    await page.getByRole('menuitemradio', { name: '週' }).click();
    await expect(page.locator('[data-testid="cal-timeline"] .tl-col')).toHaveCount(7);
    await page.getByTestId('view-menu').click();
    await page.getByRole('menuitemradio', { name: '月' }).click();
    await expect(page.getByTestId('month-view')).toBeVisible();
    await page.getByTestId('month-cell-20-in').click();
    await expect(page.getByTestId('calendar-screen')).toHaveAttribute('data-view', 'day');
    await expect(page.locator('[data-testid="cal-timeline"] .tl-col')).toHaveAttribute('data-date', String(at(0, 0, 8)));
  });

  test('赤い現在時刻線は今日の列だけ', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('tab-calendar').click();
    await expect(page.locator('[data-testid="cal-timeline"] [data-testid="tl-col-0"] [data-testid="now-line"]')).toHaveCount(1);
    await expect(page.locator('[data-testid="cal-timeline"] [data-testid="tl-col-1"] [data-testid="now-line"]')).toHaveCount(0);
    await expect(page.locator('[data-testid="cal-timeline"] [data-testid="now-label"]')).toHaveText('10:40');
  });
});

test.describe('境界ハンドル', () => {
  test.beforeEach(async ({ page }) => {
    await openApp(page);
    await seed(page, {
      tasks: [
        task({ id: 'r1', title: '実行中タスク', plannedStart: at(10), plannedEnd: at(11), status: 'running', intervals: [{ start: at(10), end: null }], actualStart: at(10) }),
        task({ id: 'n1', title: '次のタスク', plannedStart: at(13), plannedEnd: at(14) }),
        ...Array.from({ length: 8 }, (_, i) => task({ id: `x${i}`, title: `タスク${i}`, plannedStart: at(15 + i * 0.25), plannedEnd: at(16) })),
      ],
    });
  });

  test('タップでは拡張しない', async ({ page }) => {
    await page.getByTestId('split-handle').click();
    await page.waitForTimeout(400);
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-expanded', 'false');
  });

  test('上ドラッグで拡張し、縮小タスクカードが残る。下ドラッグで戻る', async ({ page }) => {
    const h = await center(page.getByTestId('split-handle'));
    await touchDrag(page, h, { x: h.x, y: h.y - 220 });
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-expanded', 'true');
    await expect(page.getByTestId('fcard-running')).toBeVisible();
    await expect(page.getByTestId('fcard-next')).toContainText('次のタスク');
    await expect(page.getByTestId('fcard-running')).toContainText('実行中タスク');
    const h2 = await center(page.getByTestId('split-handle'));
    await touchDrag(page, h2, { x: h2.x, y: h2.y + 260 });
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-expanded', 'false');
    await expect(page.getByTestId('task-row-r1')).toBeVisible();
  });

  test('タスク一覧・時間軸の縦スクロールではハンドルが動かない', async ({ page }) => {
    const before = (await page.getByTestId('split-handle').boundingBox())!.y;
    const list = await center(page.getByTestId('home-task-list'));
    await touchDrag(page, { x: list.x, y: list.y + 60 }, { x: list.x, y: list.y - 80 });
    const tl = await center(page.getByTestId('home-timeline-scroll'));
    await touchDrag(page, { x: tl.x + 40, y: tl.y + 100 }, { x: tl.x + 40, y: tl.y - 120 });
    await page.waitForTimeout(300);
    expect((await page.getByTestId('split-handle').boundingBox())!.y).toBeCloseTo(before, 0);
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-expanded', 'false');
  });
});

test.describe('作成・編集・永続化・日付', () => {
  test('タスクを作成→編集→再起動後も残る', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('home-add').click();
    await page.getByRole('menuitem', { name: '新規タスク' }).click();
    await page.getByTestId('task-title-input').fill('統計の宿題');
    await page.getByTestId('task-start').fill('2026-10-12T14:00');
    await page.getByTestId('task-end').fill('2026-10-12T15:30');
    await page.getByTestId('save-task').click();
    const row = page.locator('[data-task-title="統計の宿題"]');
    await expect(row).toBeVisible();
    await expect(row).toContainText('14:00');
    await expect(page.getByTestId('task-title-input')).toHaveCount(0); // 閉じるアニメーションの完了を待つ

    await row.locator('.task-row-main').click();
    await page.getByRole('button', { name: '編集' }).click();
    await page.getByTestId('task-title-input').fill('統計の宿題（第3章）');
    await page.getByTestId('save-task').click();
    await expect(page.getByRole('dialog').getByRole('heading', { name: '統計の宿題（第3章）' })).toBeVisible();
    await page.keyboard.press('Escape');

    await page.reload();
    await expect(page.locator('[data-task-title="統計の宿題（第3章）"]')).toBeVisible();
  });

  test('予定を作成→再起動後も残り、重なりは警告するが既存予定は動かさない', async ({ page }) => {
    await openApp(page);
    await seed(page, { events: [event({ id: 'ex', title: '授業A', calendarId: 'cal-class', start: at(13), end: at(14) })] });
    await page.getByTestId('home-add').click();
    await page.getByRole('menuitem', { name: '新規予定' }).click();
    await page.getByTestId('event-title-input').fill('面談');
    await page.getByTestId('event-start').fill('2026-10-12T13:30');
    await page.getByTestId('event-end').fill('2026-10-12T14:00');
    await expect(page.getByTestId('conflict-warning')).toContainText('授業A');
    await page.getByTestId('save-event').click();
    await page.reload();
    await expect(page.getByRole('button', { name: /予定 面談/ })).toBeVisible();
    expect((await readEvent(page, 'ex'))?.start).toBe(at(13));
  });

  test('日付を横スワイプすると上段タスクは左端の日付のものだけになる', async ({ page }) => {
    await openApp(page);
    await seed(page, {
      tasks: [
        task({ id: 'd0', title: '今日の作業', plannedStart: at(15), plannedEnd: at(16) }),
        task({ id: 'd1', title: '明日の作業', plannedStart: at(9, 0, 1), plannedEnd: at(10, 0, 1) }),
      ],
    });
    await expect(page.getByTestId('task-row-d0')).toBeVisible();
    await expect(page.getByTestId('task-row-d1')).toHaveCount(0);
    const tl = await center(page.getByTestId('home-timeline-scroll'));
    await touchDrag(page, { x: tl.x + 120, y: tl.y }, { x: tl.x - 140, y: tl.y + 4 }, { steps: 8 });
    await expect(page.getByTestId('home-date')).toContainText('13日(火)');
    await expect(page.getByTestId('task-row-d1')).toBeVisible();
    await expect(page.getByTestId('task-row-d0')).toHaveCount(0);

    // 2日表示でも上段は左端（13日）のタスク
    await page.getByTestId('days-toggle').click();
    await expect(page.getByTestId('task-row-d1')).toBeVisible();
    await expect(page.getByTestId('task-row-d0')).toHaveCount(0);

    // タスク一覧側の横スワイプでも戻せる
    const list = await center(page.getByTestId('home-task-list'));
    await touchDrag(page, { x: list.x - 120, y: list.y }, { x: list.x + 140, y: list.y + 4 }, { steps: 8 });
    await expect(page.getByTestId('home-date')).toContainText('12日(月)');
    await expect(page.getByTestId('task-row-d0')).toBeVisible();
  });
});

test.describe('進捗ジェスチャーと状態', () => {
  test.beforeEach(async ({ page }) => {
    await openApp(page);
    await seed(page, {
      tasks: [
        task({ id: 'p1', title: '進捗テスト', plannedStart: at(10), plannedEnd: at(12), status: 'running', intervals: [{ start: at(10), end: null }], actualStart: at(10) }),
        task({ id: 'p2', title: 'サブタスク親', plannedStart: at(13), plannedEnd: at(14) }),
      ],
      subtasks: [{ id: 's1', taskId: 'p2', title: '章1', done: false, completedAt: null, order: 0, createdAt: at(0), updatedAt: at(0) }],
    });
  });

  test('通常タップは詳細シートを開く', async ({ page }) => {
    await page.getByTestId('task-row-p1').locator('.task-row-main').click();
    await expect(page.getByRole('dialog')).toContainText('進捗テスト');
    await expect(page.getByTestId('progress-scrubber')).toHaveCount(0);
  });

  test('長押し→横スライドで実績を記録（理想進捗から開始）', async ({ page }) => {
    const c = await center(page.getByTestId('task-row-p1'));
    await mouseLongPressDrag(page, { x: c.box.x + 100, y: c.y }, { x: c.box.x + 100 + 60, y: c.y });
    const slider = page.getByTestId('progress-scrubber');
    await expect(slider).toBeVisible();
    const v = Number(await slider.getAttribute('aria-valuenow'));
    // 理想 = 40/120 ≒ 33% から +60px
    expect(v).toBeGreaterThan(33);
    expect(v).toBeLessThan(70);
    await page.mouse.up();
    await expect(slider).toHaveCount(0);
    await expect.poll(async () => ((await readTask(page, 'p1'))?.manualProgress as { value: number } | null)?.value).toBeCloseTo(v / 100, 1);
    await expect(page.getByTestId('task-row-p1')).toContainText(`${v}%`);
  });

  test('ドラッグしない長押しは記録しない', async ({ page }) => {
    const c = await center(page.getByTestId('task-row-p1'));
    await mouseLongPressDrag(page, { x: c.x, y: c.y }, { x: c.x, y: c.y }, 600, 1);
    await expect(page.getByTestId('progress-scrubber')).toBeVisible();
    await page.mouse.up();
    await page.waitForTimeout(200);
    expect((await readTask(page, 'p1'))?.manualProgress).toBeNull();
    await expect(page.getByRole('dialog')).toHaveCount(0);
  });

  test('100%で離すと確認。キャンセルなら未完了、承認で完了', async ({ page }) => {
    const c = await center(page.getByTestId('task-row-p1'));
    await mouseLongPressDrag(page, { x: c.box.x + 40, y: c.y }, { x: c.box.x + c.box.width + 200, y: c.y });
    await expect(page.getByTestId('progress-scrubber')).toHaveAttribute('aria-valuenow', '100');
    await page.mouse.up();
    await expect(page.getByRole('alertdialog')).toContainText('終了しますか？');
    await page.getByRole('button', { name: 'キャンセル' }).click();
    expect((await readTask(page, 'p1'))?.status).toBe('running');

    await mouseLongPressDrag(page, { x: c.box.x + 40, y: c.y }, { x: c.box.x + c.box.width + 200, y: c.y });
    await page.mouse.up();
    await page.getByRole('alertdialog').getByRole('button', { name: '終了' }).click();
    await expect.poll(async () => (await readTask(page, 'p1'))?.status).toBe('done');
  });

  test('サブタスクを持つ親は手動スライドできない', async ({ page }) => {
    const c = await center(page.getByTestId('task-row-p2'));
    await mouseLongPressDrag(page, { x: c.x, y: c.y }, { x: c.x + 80, y: c.y });
    await expect(page.getByTestId('progress-scrubber')).toHaveCount(0);
    await page.mouse.up();
    expect((await readTask(page, 'p2'))?.manualProgress).toBeNull();
  });

  test('サブタスク完了で親の実績が等分で進む', async ({ page }) => {
    await page.getByTestId('task-row-p2').locator('.task-row-main').click();
    await page.getByRole('checkbox', { name: '章1を完了' }).click();
    await page.getByPlaceholder('サブタスクを追加').fill('章2');
    await page.getByPlaceholder('サブタスクを追加').press('Enter');
    await expect(page.getByRole('dialog')).toContainText('50%');
  });

  test('一時停止・再開・終了・完了取り消しが実績とログに整合する', async ({ page }) => {
    await page.getByTestId('task-row-p1').locator('.task-row-main').click();
    const actions = page.getByTestId('task-actions');
    await actions.getByRole('button', { name: '一時停止' }).click();
    await actions.getByRole('button', { name: '再開' }).click();
    await actions.getByRole('button', { name: '終了' }).click();
    await actions.getByRole('button', { name: '完了を取り消す' }).click();
    await expect(actions.getByRole('button', { name: '再開' })).toBeVisible();
    const t = await readTask(page, 'p1');
    expect(t?.status).toBe('paused');
    expect(t?.actualEnd).toBeNull();
    for (const label of ['一時停止', '再開', '終了', '完了を取り消し']) {
      await expect(page.getByRole('dialog').locator('.log-row', { hasText: label }).first()).toBeVisible();
    }
  });
});

test.describe('時間軸', () => {
  test('予定の長押しドラッグは15分刻みで移動', async ({ page }) => {
    await openApp(page);
    await seed(page, { events: [event({ id: 'm1', title: '移動する予定', start: at(13), end: at(14) })] });
    const block = page.getByTestId('tl-event:m1');
    await block.scrollIntoViewIfNeeded();
    const c = await center(block);
    // 時間軸は 52px/時 → 50分 ≒ 43px 下へ。15分刻みで 13:45 になる
    await mouseLongPressDrag(page, { x: c.x, y: c.y }, { x: c.x, y: c.y + (52 * 50) / 60 });
    await page.mouse.up();
    await expect.poll(async () => (await readEvent(page, 'm1'))?.start).toBe(at(13, 45));
    expect((await readEvent(page, 'm1'))?.end).toBe(at(14, 45));
  });

  test('遅延タスクは現在時刻まで延長表示し、予定時刻は変更しない', async ({ page }) => {
    await openApp(page);
    await seed(page, {
      tasks: [task({ id: 'late', title: '遅延タスク', plannedStart: at(9), plannedEnd: at(10), status: 'running', intervals: [{ start: at(9), end: null }], actualStart: at(9) })],
      events: [event({ id: 'after', title: '後続', start: at(10, 15), end: at(11) })],
    });
    const block = page.getByTestId('tl-task:late');
    const box = (await block.boundingBox())!;
    // 9:00〜10:40 → 100分 ≒ 87px
    expect(box.height).toBeGreaterThan(80);
    await expect(block.locator('.tl-overrun')).toHaveCount(1);
    await expect(page.getByTestId('tl-event:after')).toHaveClass(/greyed/);
    await expect(page.getByTestId('task-row-late')).toContainText('+40分');
    expect((await readTask(page, 'late'))?.plannedEnd).toBe(at(10));
  });
});

test.describe('アクセシビリティ・画面サイズ', () => {
  for (const variant of [
    { name: 'ダーク', scheme: 'dark' as const, w: 393, size: null },
    { name: '小画面(320px)', scheme: 'light' as const, w: 320, size: null },
    { name: '大きな文字', scheme: 'light' as const, w: 393, size: 'xlarge' },
  ]) {
    test(`${variant.name}でも横はみ出しがない`, async ({ page }) => {
      await page.setViewportSize({ width: variant.w, height: 700 });
      await page.emulateMedia({ colorScheme: variant.scheme, reducedMotion: 'reduce' });
      await openApp(page);
      await seed(page, { tasks: [task({ id: 'a', title: 'とても長いタスク名が入ったときの表示確認用タスク', plannedStart: at(11), plannedEnd: at(12) })] });
      if (variant.size) {
        await page.evaluate((s) => {
          document.documentElement.dataset.textSize = s;
          document.documentElement.style.setProperty('--base-size', '22px');
        }, variant.size);
      }
      for (const t of ['home', 'calendar', 'tasks', 'analysis', 'other'] as const) {
        await page.getByTestId(`tab-${t}`).click();
        await page.waitForTimeout(100);
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
        expect(overflow, `${t} タブ`).toBeLessThanOrEqual(0);
        const tabBox = await page.getByTestId('tab-other').boundingBox();
        expect(tabBox!.x + tabBox!.width).toBeLessThanOrEqual(variant.w + 0.5);
      }
    });
  }

  test('Reduce Motion では遅延表示の明滅を使わない', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await openApp(page);
    await seed(page, { tasks: [task({ id: 'l', title: '遅延', plannedStart: at(9), plannedEnd: at(10) })] });
    await expect(page.getByTestId('task-row-l').locator('.task-row-time')).not.toHaveClass(/blink/);
    await expect(page.getByTestId('task-row-l').getByLabel('遅延', { exact: true })).toBeVisible();
  });

  test('現在時刻は固定値を使用している（テストの前提）', async ({ page }) => {
    await openApp(page);
    expect(await page.evaluate(() => Date.now())).toBe(FIXED_NOW);
  });
});
