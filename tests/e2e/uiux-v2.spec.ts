import { expect, test } from '@playwright/test';
import { at, center, event, openApp, openNewTask, pickTime, readStore, saveEditor, seed, task, touchDrag } from './helpers';

/** UI/UX v2（Q01〜Q111）の主な操作の回帰テスト */

test.describe('UI/UX v2：共通エディター', () => {
  test('＋で共通エディターを直接開き、予定⇔タスクを切り替えても入力が残る', async ({ page }) => {
    await openApp(page);
    await openNewTask(page);
    await page.getByTestId('editor-title').fill('切替でも残る 📚');
    await page.getByTestId('editor-mode-event').click();
    await expect(page.getByTestId('editor-title')).toHaveValue('切替でも残る 📚');
    await page.getByTestId('editor-mode-task').click();
    await expect(page.getByTestId('editor-title')).toHaveValue('切替でも残る 📚');
    await pickTime(page, 'editor-start-time', 16, 0);
    await saveEditor(page);
    // 入力した絵文字は削除しない
    await expect.poll(async () => (await readStore(page, 'tasks')).find((t) => t.title === '切替でも残る 📚')?.plannedStart).toBe(at(16));
  });

  test('入力途中で閉じると破棄の確認を出し、「編集を続ける」で内容が残る', async ({ page }) => {
    await openApp(page);
    await openNewTask(page);
    await page.getByTestId('editor-title').fill('途中');
    await page.getByRole('button', { name: 'キャンセル' }).click();
    const dlg = page.getByRole('alertdialog');
    await expect(dlg).toContainText('変更を破棄しますか？');
    await dlg.getByRole('button', { name: '編集を続ける' }).click();
    await expect(page.getByTestId('editor-title')).toHaveValue('途中');
    await page.getByRole('button', { name: 'キャンセル' }).click();
    await page.getByRole('alertdialog').getByRole('button', { name: '変更を破棄' }).click();
    await expect(page.getByTestId('editor-sheet')).toHaveCount(0);
    expect((await readStore(page, 'tasks')).length).toBe(0);
  });

  test('複数の通知を保存し、予定にも使える', async ({ page }) => {
    await openApp(page);
    await openNewTask(page);
    await page.getByTestId('editor-title').fill('通知テスト');
    await pickTime(page, 'editor-start-time', 15, 0);
    await page.getByTestId('editor-tab-option').click();
    await page.getByTestId('editor-notify').click();
    const pop = page.getByTestId('notify-popup');
    await expect(pop).toBeVisible();
    // 既定の通知が入っていることもあるので、10分前と1時間前だけが選ばれた状態にする
    for (const it of await pop.getByRole('menuitemcheckbox', { checked: true }).all()) {
      const name = (await it.textContent()) ?? '';
      if (!/^(10分前|1時間前)/.test(name)) await it.click();
    }
    for (const n of [/^10分前/, /^1時間前/]) {
      const it = pop.getByRole('menuitemcheckbox', { name: n }).first();
      if ((await it.getAttribute('aria-checked')) !== 'true') await it.click();
    }
    await pop.getByRole('button', { name: '完了' }).click();
    await saveEditor(page);
    const t = (await readStore(page, 'tasks')).find((x) => x.title === '通知テスト')!;
    expect(((t.extra as { notifies: number[] }).notifies).sort((a, b) => a - b)).toEqual([10, 60]);
  });
});

test.describe('UI/UX v2：一覧と削除の取り消し', () => {
  test('タスクを左スワイプで削除し、取り消しで元に戻る（数秒は保存しない）', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 'sw', title: 'スワイプ削除', plannedStart: at(15), plannedEnd: at(16) })] });
    await page.getByTestId('tab-tasks').click();
    const row = page.getByTestId('swipe-sw');
    await expect(row).toBeVisible();
    const c = await center(row);
    // 浅いスワイプで操作ボタンを出す（深く引くとそのまま削除）
    await touchDrag(page, { x: c.x + 60, y: c.y }, { x: c.x - 100, y: c.y + 2 }, { steps: 10 });
    await page.getByTestId('swipe-sw').locator('.swipe-act', { hasText: '削除' }).click();
    await expect(page.getByTestId('undo-bar')).toBeVisible();
    await expect(page.getByTestId('swipe-sw')).toHaveCount(0);
    // 取り消し待ちの間は保存データを変えない
    expect((await readStore(page, 'tasks')).some((t) => t.id === 'sw')).toBe(true);
    await page.getByTestId('undo-delete').click();
    await expect(page.getByTestId('swipe-sw')).toBeVisible();
    await page.waitForTimeout(5500);
    expect((await readStore(page, 'tasks')).some((t) => t.id === 'sw')).toBe(true);
  });

  test('タブバーは指を滑らせて選び、離したタブが確定する', async ({ page }) => {
    await openApp(page);
    const from = await center(page.getByTestId('tab-home'));
    const to = await center(page.getByTestId('tab-analysis'));
    await touchDrag(page, from, { x: to.x, y: to.y }, { steps: 12 });
    await expect(page.getByTestId('tab-analysis')).toHaveAttribute('aria-current', 'page');
    await expect(page.getByTestId('analysis-screen')).toBeVisible();
  });
});

test.describe('UI/UX v2：時間軸', () => {
  test('予定のタップは情報確認（約半分の高さ）を開き、編集は鉛筆から', async ({ page }) => {
    await openApp(page);
    await seed(page, { events: [event({ id: 'iv', title: '情報確認', start: at(15), end: at(16) })] });
    await page.getByTestId('tl-event:iv').scrollIntoViewIfNeeded();
    await page.getByTestId('tl-event:iv').click();
    await expect(page.getByTestId('event-info')).toBeVisible();
    await expect(page.getByTestId('editor-sheet')).toHaveCount(0);
    await page.getByTestId('info-edit').click();
    await expect(page.getByTestId('editor-title')).toHaveValue('情報確認');
  });
});

test.describe('UI/UX v2：Create Studio とカテゴリー', () => {
  test('空白から種類を作り、作成画面の専用タブで入力して保存できる', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('tab-other').click();
    await page.getByTestId('nav-studio').click();
    await page.getByTestId('studio-new-task').click();
    // テンプレートなし：最初は項目が空
    await expect(page.locator('[data-field-id]')).toHaveCount(0);
    await page.getByTestId('studio-name').fill('読書');
    await page.getByTestId('studio-part-search').fill('ページ');
    await page.getByTestId('part-number').click();
    await expect(page.getByTestId('field-label')).toHaveValue('ページ数');
    await page.getByTestId('field-editor').getByRole('button', { name: '追加' }).click();
    await page.getByTestId('progress-number').click();
    await page.getByTestId('progress-target').fill('300');
    await page.getByTestId('studio-save').click();
    await expect(page.getByTestId('studio-card-読書')).toBeVisible();
    const st = (await readStore(page, 'studioTypes'))[0]!;
    expect(st).toMatchObject({ name: '読書', target: 'task', status: 'active' });

    await page.getByTestId('tab-home').click();
    await openNewTask(page);
    await page.getByTestId('editor-title').fill('小説を読む');
    await page.getByTestId('editor-type').click();
    await page.getByTestId(`type-studio-${st.id as string}`).click();
    await page.getByTestId('editor-tab-special').click();
    await page.getByTestId('studio-fields').getByRole('spinbutton').first().fill('120');
    await saveEditor(page);
    const t = (await readStore(page, 'tasks')).find((x) => x.title === '小説を読む')!;
    expect((t.extra as { studio: { typeId: string; values: Record<string, unknown> } }).studio.typeId).toBe(st.id);
    expect(Object.values((t.extra as { studio: { values: Record<string, unknown> } }).studio.values)).toContain(120);
  });

  test('カテゴリーを追加できる', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('tab-other').click();
    await page.getByTestId('nav-categories').click();
    await page.getByTestId('add-category').click();
    await page.getByTestId('category-name').fill('ゼミ');
    await page.getByTestId('category-editor').getByRole('button', { name: '保存' }).click();
    await expect.poll(async () => (await readStore(page, 'categories')).map((c) => c.name)).toContain('ゼミ');
  });
});

test.describe('UI/UX v2：分析・お知らせ', () => {
  test('日・週・月・年を切り替え、前後へ移動でき、記録がない期間は空の表示', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 'an', title: '分析', plannedStart: at(8), plannedEnd: at(9), status: 'done', actualStart: at(8), actualEnd: at(9), intervals: [{ start: at(8), end: at(9) }] })] });
    await page.getByTestId('tab-analysis').click();
    await expect(page.getByTestId('tile-work')).toContainText('1時間');
    for (const p of ['week', 'month', 'year'] as const) {
      await page.getByTestId(`period-${p}`).click();
      await expect(page.getByTestId('tile-work')).toContainText('1時間');
    }
    await page.getByTestId('period-label').click(); // 今日へ戻る
    await page.getByTestId('next-period').click();
    await expect(page.getByTestId('analysis-empty')).toBeVisible();
    await page.getByTestId('prev-period').click();
    await page.getByTestId('tile-completion').click();
    await expect(page.getByTestId('analysis-detail')).toContainText('分析');
  });

  test('お知らせがないときは空の表示', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('tab-other').click();
    await page.getByTestId('nav-notices').click();
    await expect(page.getByTestId('notices-empty')).toBeVisible();
  });
});
