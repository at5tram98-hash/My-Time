import { expect, test } from '@playwright/test';
import { at, center, event, openApp, openNewTask, pickDate, pickTime, readStore, saveEditor, seed, task, touchDrag } from './helpers';

/** 指示書 v3（C01〜C35・F1〜F6・R1〜R3）の受入条件の自動確認 */

test.describe('v3 ホーム', () => {
  test('C01/v3.1：一覧→円（Dynamic Island 風）→さらに上で非表示（線が残る）→線を下で円に戻る', async ({ page, browserName }) => {
    test.skip(browserName !== 'chromium', 'CDP のタッチ入力が必要');
    await openApp(page);
    await seed(page, { tasks: [task({ id: 'r1', title: '実行中', plannedStart: at(10), plannedEnd: at(11), status: 'running', intervals: [{ start: at(10), end: null }], actualStart: at(10) })] });
    const h = await center(page.getByTestId('split-handle'));
    await touchDrag(page, h, { x: h.x, y: h.y - 400 });
    // 1回目の上スライドではまだ消えない（円が残る）
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-expanded', 'true');
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-hidden', 'false');
    await expect(page.getByTestId('split-handle')).toHaveCount(0);
    // v3.2：Dynamic Island ほどのカプセル。名前と経過時間を出す
    await expect(page.getByTestId('fcard-running')).toContainText('実行中');
    expect((await page.getByTestId('fcard-running').boundingBox())!.width).toBeGreaterThan(120);
    await page.waitForTimeout(500);
    const row = await center(page.getByTestId('compact-row'));
    await touchDrag(page, { x: row.x, y: row.y }, { x: row.x, y: row.y - 60 }, { steps: 8 });
    // 2回目で非表示。タブは移動せず、上に線が残る
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-hidden', 'true');
    await expect(page.getByTestId('tab-home')).toHaveAttribute('aria-current', 'page');
    await expect(page.getByTestId('tasks-hidden-line')).toBeVisible();
    await expect.poll(async () => (await page.getByTestId('task-pane').boundingBox())?.height ?? 0).toBeLessThan(1);
    await page.waitForTimeout(400);
    const line = await center(page.getByTestId('tasks-hidden-line'));
    await touchDrag(page, line, { x: line.x, y: line.y + 60 }, { steps: 8 });
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-hidden', 'false');
    await expect(page.getByTestId('floating-cards')).toBeVisible();
  });

  test('空の日も最小化カプセルを残し、非表示と復帰を操作できる', async ({ page }) => {
    await openApp(page);
    await page.getByRole('button', { name: 'その他の操作' }).click();
    await page.getByRole('menuitem', { name: 'タスクをコンパクト表示' }).click();
    await expect(page.getByTestId('floating-cards')).toContainText('次のタスクはありません');
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-hidden', 'false');
    await expect.poll(async () => (await page.getByTestId('task-pane').boundingBox())?.height ?? 0).toBeGreaterThan(50);
    await page.getByRole('button', { name: 'その他の操作' }).click();
    await page.getByRole('menuitem', { name: 'タスク表示を隠す' }).click();
    await expect(page.getByTestId('tasks-hidden-line')).toBeVisible();
    await page.getByTestId('tasks-hidden-line').focus();
    await page.keyboard.press('Enter');
    await expect(page.getByTestId('floating-cards')).toBeVisible();
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-hidden', 'false');
  });

  test('v3.1：カレンダー選択から新しいカレンダーを追加できる', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('tab-calendar').click();
    await page.getByTestId('cal-filter').click();
    await page.getByTestId('filter-add-calendar').click();
    await page.getByTestId('filter-add-name').fill('ゼミ');
    await page.getByTestId('filter-add-save').click();
    await expect(page.getByTestId('calendar-filter')).toContainText('ゼミ');
    await expect.poll(async () => (await readStore(page, 'calendars') as { name: string }[]).some((c) => c.name === 'ゼミ')).toBe(true);
  });

  test('C02：メニューに1日／2日の重複がなく、「日付を選択」で閏日へ移動できる', async ({ page }) => {
    await openApp(page);
    await page.getByRole('button', { name: 'その他の操作' }).click();
    await expect(page.getByRole('menuitem', { name: /日表示にする/ })).toHaveCount(0);
    await page.getByRole('menuitem', { name: '日付を選択' }).click();
    const p = page.getByTestId('date-picker');
    for (const [name, label] of [['年', '2028年'], ['月', '2月'], ['日', '29日']] as const) {
      await p.getByRole('listbox', { name }).evaluate((el, lb) => { const o = [...el.querySelectorAll('[role=option]')]; el.scrollTop = o.findIndex((x) => x.textContent === lb) * 40; el.dispatchEvent(new Event('scroll')); }, label);
      await expect(p.getByRole('listbox', { name }).getByRole('option', { name: label, exact: true })).toHaveAttribute('aria-selected', 'true');
    }
    await expect(p.getByTestId('date-summary')).toContainText('2028年2月29日');
    await p.getByRole('button', { name: '完了' }).click();
    await expect(page.getByTestId('home-date')).toContainText('2028年2月');
    await expect(page.getByTestId('home-date')).toContainText('29日');
  });
});

test.describe('v3 アイコンと種別色', () => {
  test('C05・C25：リング中央の図形がリングの中心にある（0%・20%・100%）', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 'p0', title: '未入力', plannedStart: at(13), plannedEnd: at(14) }), task({ id: 'p20', title: '20%', plannedStart: at(15), plannedEnd: at(16), manualProgress: { value: 0.2, at: at(10), workedMsAtSample: 0 } }), task({ id: 'p100', title: '完了', plannedStart: at(8), plannedEnd: at(9), status: 'done', actualStart: at(8), actualEnd: at(9), intervals: [{ start: at(8), end: at(9) }] })] });
    for (const id of ['p0', 'p20', 'p100']) {
      await page.getByTestId(`task-row-${id}`).locator('.task-row-main').click();
      const ring = page.getByTestId('run-ring').locator('.ident').first();
      await expect(ring).toBeVisible();
      const off = await ring.evaluate((el) => {
        const r = el.getBoundingClientRect();
        const g = el.querySelector('.ident-disc svg')!.getBoundingClientRect();
        return Math.hypot(r.x + r.width / 2 - (g.x + g.width / 2), r.y + r.height / 2 - (g.y + g.height / 2));
      });
      expect(off, id).toBeLessThanOrEqual(1);
      await page.keyboard.press('Escape');
      await expect(page.getByTestId('task-info')).toHaveCount(0);
    }
  });

  test('C10：実行は赤・確認は青の独立ボタン（セグメントではない）', async ({ page }) => {
    await openApp(page);
    await openNewTask(page);
    const doBtn = page.getByTestId('editor-kind-do');
    const ck = page.getByTestId('editor-kind-check');
    await expect(doBtn).toHaveAttribute('aria-pressed', 'true');
    const bg = (l: typeof doBtn) => l.evaluate((el) => getComputedStyle(el).backgroundColor);
    await expect.poll(() => bg(doBtn)).toMatch(/rgb\(255, 59, 48\)/);
    await ck.click();
    await expect(ck).toHaveAttribute('aria-pressed', 'true');
    await expect.poll(() => bg(ck)).toMatch(/rgb\(0, 122, 255\)/); // 色の切替アニメーション後
    // 独立した2つのボタン（間に共通の灰色トラックがない）
    const gap = await page.locator('.kind-buttons').first().evaluate((el) => getComputedStyle(el).backgroundColor);
    expect(gap).toBe('rgba(0, 0, 0, 0)');
  });
});

test.describe('v3 編集と情報確認', () => {
  test('C14・C17・F3：場所を直接入力し移動時間と一緒に保存。情報確認では場所は1か所（座標なしは偽の地図を出さない）', async ({ page }) => {
    await openApp(page);
    await openNewTask(page);
    await page.getByTestId('editor-title').fill('図書館で勉強');
    await pickTime(page, 'editor-start-time', 16, 0);
    await page.getByTestId('editor-place').click();
    const pop = page.getByTestId('place-popup');
    await pop.getByTestId('place-manual-toggle').click();
    await pop.getByTestId('place-name').fill('大学図書館');
    await pop.getByTestId('place-use-manual').click();
    await pop.getByTestId('travel-15').click();
    await expect(pop).toContainText('出発の目安 15:45');
    await pop.getByRole('button', { name: '完了' }).click();
    await expect(page.getByTestId('editor-place')).toContainText('大学図書館 · 移動15分');
    await saveEditor(page);
    const t = (await readStore(page, 'tasks')).find((x) => x.title === '図書館で勉強')!;
    expect(t.extra).toMatchObject({ place: { name: '大学図書館', lat: null }, travelMinutes: 15 });
    await page.locator('[data-task-title="図書館で勉強"]').locator('.task-row-main').click();
    const info = page.getByTestId('task-info');
    await expect(info.getByText('大学図書館')).toHaveCount(1);
    await expect(info.getByTestId('map-fallback')).toBeVisible();
    await expect(info.getByTestId('map-preview')).toHaveCount(0);
  });

  test('F1・C18・C23：通知は基本タブで複数選び、情報確認に全件出る', async ({ page }) => {
    await openApp(page);
    await openNewTask(page);
    await page.getByTestId('editor-title').fill('通知2件');
    await pickTime(page, 'editor-start-time', 17, 0);
    await expect(page.getByTestId('editor-page-basic').getByTestId('editor-notify')).toBeVisible();
    await page.getByTestId('editor-notify').click();
    const pop = page.getByTestId('notify-popup');
    for (const it of await pop.getByRole('menuitemcheckbox', { checked: true }).all()) await it.click();
    await pop.getByRole('menuitemcheckbox', { name: /^5分前/ }).click();
    await pop.getByRole('menuitemcheckbox', { name: /^15分前/ }).click();
    await expect(pop.getByTestId('notify-summary')).toContainText('5分前');
    await pop.getByRole('button', { name: '完了' }).click();
    await saveEditor(page);
    await page.locator('[data-task-title="通知2件"]').locator('.task-row-main').click();
    await expect(page.getByTestId('info-notify')).toHaveText('15分前・5分前');
  });

  test('C21・C19：タグはチップに分かれ、カテゴリーは選択シートで選ぶ', async ({ page }) => {
    await openApp(page);
    await openNewTask(page);
    await page.getByTestId('editor-title').fill('タグ');
    await page.getByTestId('editor-tab-option').click();
    await page.getByTestId('tag-draft').fill('#ゼミ #レポート ');
    await expect(page.getByTestId('tag-input').locator('.tag-chip')).toHaveCount(2);
    await page.getByTestId('tag-draft').fill('ゼミ');
    await page.getByTestId('tag-draft').press('Enter');
    await expect(page.getByTestId('tag-input').locator('.tag-chip')).toHaveCount(2); // 重複は1つ
    await saveEditor(page);
    expect((await readStore(page, 'tasks')).find((x) => x.title === 'タグ')!.tags).toEqual(['ゼミ', 'レポート']);
  });

  test('C07・C08：サブタスクに日時と見積を設定・保持し、実績ログは初期は閉じている', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 'pt', title: '親', plannedStart: at(13), plannedEnd: at(15) })], subtasks: [{ id: 'st1', taskId: 'pt', title: '構成', done: false, completedAt: null, order: 0, createdAt: at(9), updatedAt: at(9) }] });
    await page.getByTestId('task-row-pt').locator('.task-row-main').click();
    await expect(page.getByTestId('log-toggle')).toHaveAttribute('aria-expanded', 'false');
    await page.getByTestId('sub-time-st1').click();
    const pop = page.getByTestId('sub-time-popup');
    await pop.getByRole('switch', { name: '日時を指定' }).click();
    await pickTime(page, 'sub-start-time', 13, 30);
    await pop.getByTestId('sub-estimate').fill('25');
    await pop.getByRole('button', { name: '完了' }).click();
    await expect(page.getByTestId('sub-time')).toContainText('13:30');
    await expect(page.getByTestId('sub-time')).toContainText('見積25分');
    const s = (await readStore(page, 'subtasks')).find((x) => x.id === 'st1')!;
    expect(s).toMatchObject({ plannedStart: at(13, 30), plannedEnd: null, estimateMinutes: 25 });
    // チェックしても日時は消えない
    await page.getByRole('checkbox', { name: '構成を完了' }).click();
    await expect.poll(async () => (await readStore(page, 'subtasks')).find((x) => x.id === 'st1')!.plannedStart).toBe(at(13, 30));
  });

  test('F2：Studio 数値 20/100 はリング・実績欄・進捗パネルで同じ根拠と値', async ({ page }) => {
    await openApp(page);
    await page.evaluate(async (now) => {
      const db: IDBDatabase = await new Promise((r) => { const q = indexedDB.open('my-time'); q.onsuccess = () => r(q.result); });
      const tx = db.transaction(['studioTypes', 'tasks'], 'readwrite');
      tx.objectStore('studioTypes').put({ id: 'sty', target: 'task', name: '読書', icon: 'book', color: '#34C759', status: 'active', version: 1, revisions: [], sections: [{ id: 's', title: '基本' }], fields: [{ id: 'pg', type: 'number', label: '読んだページ', unit: 'page', showInInfo: true, sectionId: 's' }], progress: { mode: 'number', fieldId: 'pg', target: 100 }, createdAt: now, updatedAt: now });
      await new Promise((r) => { tx.oncomplete = r; });
      db.close();
    }, at(9));
    await seed(page, { tasks: [task({ id: 'stt', title: '小説', plannedStart: at(13), plannedEnd: at(14), extra: { studio: { typeId: 'sty', version: 1, values: { pg: 20 } } } })] });
    await page.reload();
    await page.getByTestId('task-row-stt').locator('.task-row-main').click();
    await expect(page.getByTestId('run-progress')).toHaveText('20/100ページ');
    await expect(page.getByTestId('progress-group')).toContainText('20/100ページ（20%）');
    await page.getByTestId('run-ring').click();
    await expect(page.getByTestId('pp-value')).toHaveText('20%');
    await page.getByTestId('pp-studio').fill('34');
    await page.getByTestId('progress-popup').getByRole('button', { name: '完了' }).click();
    await expect(page.getByTestId('run-progress')).toHaveText('34/100ページ');
    const t = (await readStore(page, 'tasks')).find((x) => x.id === 'stt')!;
    expect((t.extra as { studio: { values: { pg: number } } }).studio.values.pg).toBe(34);
    expect(t.manualProgress).toBeNull();
  });

  test('F5：シートの見出しIDが一意で、ダイアログ名がタスク名になる', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 'u1', title: '一意', plannedStart: at(13), plannedEnd: at(14) })] });
    await page.getByTestId('task-row-u1').locator('.task-row-main').click();
    const dlg = page.getByRole('dialog', { name: '一意' });
    await expect(dlg).toBeVisible();
    const dup = await page.evaluate(() => { const ids = [...document.querySelectorAll('[id]')].map((e) => e.id); return ids.filter((x, i) => ids.indexOf(x) !== i); });
    expect(dup).toEqual([]);
  });
});

test.describe('v3 一覧・設定', () => {
  test('C29：タグ別グループでは複数タグのタスクが各タグに出るが、件数は重複しない', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 'g1', title: '両方', tags: ['ゼミ', 'レポート'], plannedStart: at(15), plannedEnd: at(16) }), task({ id: 'g2', title: 'なし', plannedStart: at(17), plannedEnd: at(18) })] });
    await page.getByTestId('tab-tasks').click();
    await page.getByTestId('scope-all').click();
    await expect(page.getByTestId('scope-all')).toContainText('2');
    await page.getByTestId('tasks-group').click();
    await page.getByTestId('group-popup').getByRole('radio', { name: /タグ/ }).first().click();
    await expect(page.getByTestId('group-#ゼミ')).toContainText('両方');
    await expect(page.getByTestId('group-#レポート')).toContainText('両方');
    await expect(page.getByTestId('group-タグなし')).toContainText('なし');
    await expect(page.getByTestId('scope-all')).toContainText('2');
  });

  test('C32：カレンダーの並べ替えは矢印ボタンなし。ハンドルのキーボード操作で並び替えて保持', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('tab-other').click();
    await page.getByTestId('nav-calendars').click();
    await expect(page.getByRole('button', { name: /を上へ|を下へ/ })).toHaveCount(0);
    const h = page.getByTestId('calendar-handle-cal-general');
    await h.focus();
    await h.press('Space');
    await h.press('ArrowDown');
    await page.getByTestId('calendar-handle-cal-general').press('Space');
    await expect.poll(async () => (await readStore(page, 'calendars')).sort((a, b) => (a.order as number) - (b.order as number)).map((c) => c.id)).toEqual(['cal-class', 'cal-general', 'cal-job']);
  });

  test('C33：カレンダー追加の途中で専用の種類を作り、戻って選択済みのまま保存できる', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('tab-other').click();
    await page.getByTestId('nav-calendars').click();
    await page.getByTestId('add-calendar').click();
    await page.getByTestId('calendar-name').fill('ゼミ');
    await page.getByTestId('cal-new-studio').click();
    await page.getByTestId('studio-name').fill('ゼミ記録');
    await page.getByTestId('studio-part-search').fill('メモ');
    await page.locator('[data-testid^="part-"]').first().click();
    await page.getByTestId('field-editor').getByRole('button', { name: '追加' }).click();
    await page.getByTestId('studio-save').click();
    await expect(page.getByTestId('calendar-name')).toHaveValue('ゼミ');
    const st = (await readStore(page, 'studioTypes'))[0]!;
    await expect(page.getByTestId(`cal-kind-studio-${st.id as string}`)).toHaveAttribute('aria-checked', 'true');
    await page.getByTestId('save-calendar').click();
    const cals = await readStore(page, 'calendars');
    expect(cals.filter((c) => c.studioTypeId === st.id).map((c) => c.name)).toEqual(['ゼミ']);
  });

  test('C35：外観は一覧から詳細画面に入って選ぶ', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('tab-other').click();
    await expect(page.getByTestId('theme-menu')).toHaveCount(0);
    await page.getByTestId('nav-appearance').click();
    await page.getByTestId('theme-dark').click();
    await expect.poll(async () => (await readStore(page, 'settings'))[0]?.theme).toBe('dark');
    await page.getByTestId('back').click();
    await expect(page.getByTestId('nav-appearance')).toContainText('ダーク');
  });
});

test('R1：未完了のサブタスクがある親を完了するときは確認し、子は自動で完了にしない', async ({ page }) => {
  await openApp(page);
  await seed(page, { tasks: [task({ id: 'r1p', title: '親R1', plannedStart: at(10), plannedEnd: at(12), status: 'running', actualStart: at(10), intervals: [{ start: at(10), end: null }] })], subtasks: [{ id: 'r1s', taskId: 'r1p', title: '子', done: false, completedAt: null, order: 0, createdAt: at(9), updatedAt: at(9) }] });
  await page.getByTestId('task-row-r1p').locator('.task-row-main').click();
  await page.getByTestId('run-finish').click();
  await expect(page.getByRole('alertdialog')).toContainText('未完了のサブタスクがあります');
  await page.getByRole('alertdialog').getByRole('button', { name: '完了にする' }).click();
  await expect.poll(async () => (await readStore(page, 'tasks')).find((t) => t.id === 'r1p')!.status).toBe('done');
  expect((await readStore(page, 'subtasks')).find((s) => s.id === 'r1s')!.done).toBe(false);
  await expect(page.getByTestId('progress-group')).toContainText('未完了のサブタスク1件');
});

void event;
void pickDate;

test.describe('v3.1 回帰：入力中にフォーカスが外れない', () => {
  test('タスク・予定のタイトル、メモ、場所検索で1文字ずつ入力しても入力欄にフォーカスが残る', async ({ page }) => {
    await openApp(page);
    await openNewTask(page);
    const title = page.getByTestId('editor-title');
    await title.click();
    await page.keyboard.type('レポート提出', { delay: 60 });
    await page.waitForTimeout(600);
    await expect(title).toHaveValue('レポート提出');
    await expect(title).toBeFocused();
    await page.getByTestId('editor-place').click();
    const q = page.getByTestId('place-query');
    await q.click();
    await page.keyboard.type('kyoto', { delay: 80 });
    await page.waitForTimeout(1500);
    await expect(q).toHaveValue('kyoto');
    await expect(q).toBeFocused();
    await page.getByTestId('place-popup').getByRole('button', { name: 'キャンセル' }).click();
    await saveEditor(page);
    await page.getByTestId('home-add').click();
    await page.getByRole('tab', { name: '予定' }).or(page.getByRole('button', { name: '予定', exact: true })).first().click();
    const et = page.getByTestId('editor-title');
    await et.click();
    await page.keyboard.type('ゼミ発表', { delay: 60 });
    await expect(et).toHaveValue('ゼミ発表');
    await expect(et).toBeFocused();
  });
});
