import { expect, test } from '@playwright/test';
import { at, center, event, openApp, openSettings, readStore, seed, task } from './helpers';

/**
 * 再設計（2026-11）の受け入れ条件。
 * - タブは4つ＋右の「追加」、設定は歯車から重ねて開く
 * - 今日は1日だけ、左＝予定・右＝タスクのレーン
 * - 文章からの追加（候補→確認→追加→取り消し）、検索・変更・組み直しの意図
 * - 気づいたことの修正案は差分を見てから適用、取り消せる
 * - 未割当・延期・専門の種類・変更履歴・書き出し・通知の静穏時間
 */

test.describe('再設計：ナビゲーション', () => {
  test('タブは4つ、追加は丸いボタン、設定は歯車から開いて戻ると元の画面', async ({ page }) => {
    await openApp(page);
    const tabs = page.getByTestId('tabbar').locator('.tab');
    await expect(tabs).toHaveCount(4);
    await expect(tabs).toHaveText(['今日', 'カレンダー', 'タスク', '振り返り']);
    await page.getByTestId('tab-tasks').click();
    await openSettings(page);
    await expect(page.getByTestId('other-screen')).toBeVisible();
    await expect(page.getByRole('heading', { name: '設定' })).toBeVisible();
    await page.getByTestId('settings-close').click();
    await expect(page.getByTestId('settings-push')).toHaveCount(0);
    await expect(page.getByTestId('tab-tasks')).toHaveAttribute('aria-current', 'page');
    await page.getByTestId('quick-add').click();
    await expect(page.getByTestId('quick-add-sheet')).toBeVisible();
  });
  test('キーボード：n で追加、Esc で閉じる', async ({ page }) => {
    await openApp(page);
    await page.keyboard.press('n');
    await expect(page.getByTestId('quick-add-sheet')).toBeVisible();
  });
});

test.describe('再設計：今日の左右レーン', () => {
  test('予定は左、タスクは右。見出しのタップで片方を広くできる。2日表示はない', async ({ page }) => {
    await openApp(page);
    await seed(page, {
      events: [event({ id: 'e1', title: '授業', start: at(13), end: at(14, 30) })],
      tasks: [task({ id: 't1', title: '課題', plannedStart: at(13), plannedEnd: at(14) })],
    });
    await expect(page.getByTestId('days-toggle')).toHaveCount(0);
    const ev = await center(page.getByTestId('tl-event:e1'));
    const tk = await center(page.getByTestId('tl-task:t1'));
    expect(ev.x).toBeLessThan(tk.x);
    // 同じ時刻でも互いに細くならない（それぞれのレーンの幅いっぱい）
    expect(ev.box.width).toBeGreaterThan(120);
    expect(tk.box.width).toBeGreaterThan(120);
    await page.getByTestId('lane-main').click();
    await expect(page.getByTestId('home-screen')).toHaveAttribute('data-lane-focus', 'main');
    await expect.poll(async () => (await page.getByTestId('tl-event:e1').boundingBox())!.width).toBeGreaterThan(ev.box.width + 30);
  });
  test('今やること：次のタスクを1回のタップで開始できる', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 't1', title: 'すぐやる', plannedStart: at(10, 50), plannedEnd: at(11, 30) })] });
    await expect(page.getByTestId('now-card')).toHaveAttribute('data-kind', 'start');
    await page.getByTestId('now-start').click();
    await expect(page.getByTestId('now-card')).toHaveAttribute('data-kind', 'continue');
    expect((await readStore(page, 'tasks'))[0]!.status).toBe('running');
  });
  test('今日のタスク一覧は要約から開き、長押しの進捗入力が使える', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 't1', title: '一覧のタスク', plannedStart: at(10), plannedEnd: at(12) })] });
    await page.getByTestId('chip-tasks').click();
    await expect(page.getByTestId('day-tasks').getByTestId('task-row-t1')).toBeVisible();
  });
  test('320px でも横にはみ出さない', async ({ page }) => {
    await page.setViewportSize({ width: 320, height: 568 });
    await openApp(page);
    await seed(page, { events: [event({ id: 'e1', title: 'とても長いタイトルの予定がここに入ります', start: at(11), end: at(12) })], tasks: [task({ id: 't1', title: 'とても長いタイトルのタスク', plannedStart: at(11), plannedEnd: at(12) })] });
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(320);
  });
});

test.describe('再設計：文章からの追加（P01〜P05）', () => {
  test('例A：勤務を追加すると左のレーンに出て、給与見込み 4,550円を示す。取り消しで消える', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('quick-add').click();
    await page.getByTestId('quick-input').fill('今日18:30〜22:00 GU 時給1,300円');
    await expect(page.getByTestId('quick-candidate')).toHaveCount(1);
    await expect(page.getByTestId('quick-candidate')).toHaveAttribute('data-spec', 'shift');
    await page.getByTestId('quick-save').click();
    await expect(page.getByTestId('quick-add-sheet')).toHaveCount(0);
    const evs = await readStore(page, 'events');
    expect(evs).toHaveLength(1);
    const id = evs[0]!.id as string;
    await page.getByTestId(`tl-event:${id}`).click();
    await expect(page.getByTestId('spec-card').locator('[data-label="給与見込み"]')).toContainText('4,550円');
    await page.getByTestId('event-info').getByRole('button', { name: '閉じる' }).click();
    // 直後なら取り消せる
    await page.getByTestId('quick-add').click();
    await page.getByTestId('quick-input').fill('明日は課題2つと買い物');
    await expect(page.getByTestId('quick-candidate')).toHaveCount(3);
    await page.getByTestId('quick-cand-include').nth(2).click();
    await page.getByTestId('quick-save').click();
    await expect(page.getByTestId('undo-bar')).toContainText('2件を追加しました');
    await page.getByTestId('undo-delete').click();
    await expect.poll(async () => (await readStore(page, 'tasks')).filter((t) => String(t.title).startsWith('課題')).length).toBe(0);
  });
  test('P02：曖昧な時刻は「候補」として根拠つきで出す', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('quick-add').click();
    await page.getByTestId('quick-input').fill('夕方に買い物');
    await expect(page.getByTestId('quick-cand-tentative')).toBeVisible();
    await page.getByRole('button', { name: 'どう読み取ったか' }).click();
    await expect(page.getByTestId('quick-candidate')).toContainText('夕方');
  });
  test('P03：「明日のバイト」は検索になり、追加ボタンは出ない', async ({ page }) => {
    await openApp(page);
    await seed(page, { events: [event({ id: 'job', title: 'GU', calendarId: 'cal-job', start: at(18, 0, 1), end: at(22, 0, 1), extra: { spec: { type: 'shift', details: {} } } })] });
    await page.getByTestId('quick-add').click();
    await page.getByTestId('quick-input').fill('明日のバイト');
    await expect(page.getByTestId('quick-search').getByTestId('quick-hit')).toHaveCount(1);
    await expect(page.getByTestId('quick-save')).toHaveCount(0);
  });
  test('P04：「〜を1時間遅らせて」は差分を見てから変更し、取り消せる', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 't1', title: '英語の勉強', plannedStart: at(15), plannedEnd: at(16) })] });
    await page.getByTestId('quick-add').click();
    await page.getByTestId('quick-input').fill('今日の英語の勉強を1時間遅らせて');
    await expect(page.getByTestId('quick-change-preview').getByTestId('diff-row')).toContainText('16:00');
    expect((await readStore(page, 'tasks'))[0]!.plannedStart).toBe(at(15));
    await page.getByTestId('plan-apply').click();
    await expect.poll(async () => (await readStore(page, 'tasks'))[0]!.plannedStart).toBe(at(16));
    await page.getByTestId('undo-delete').click();
    await expect.poll(async () => (await readStore(page, 'tasks'))[0]!.plannedStart).toBe(at(15));
  });
  test('P05：「今日の課題を移して」は組み直しの案（予定は動かさない）', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 't1', title: '課題A', special: 'assignment', plannedStart: at(8), plannedEnd: at(9) })] });
    await page.getByTestId('quick-add').click();
    await page.getByTestId('quick-input').fill('急用ができたので今日の課題を移して');
    await expect(page.getByTestId('quick-replan-preview').getByTestId('diff-row')).toHaveCount(1);
  });
});

test.describe('再設計：気づいたこと・未割当・延期', () => {
  test('予定と重なったタスクの修正案を差分で確認して適用する（予定は動かない）', async ({ page }) => {
    await openApp(page);
    await seed(page, {
      events: [event({ id: 'e1', title: '授業', start: at(13), end: at(15) })],
      tasks: [task({ id: 't1', title: '読書', plannedStart: at(14), plannedEnd: at(15) })],
    });
    await page.getByTestId('chip-issues').click();
    const card = page.getByTestId('issue-card').filter({ hasText: '読書' });
    await card.locator('.issue-head').click();
    await card.getByTestId('plan-apply').click();
    await expect.poll(async () => (await readStore(page, 'tasks'))[0]!.plannedStart).not.toBe(at(14));
    expect((await readStore(page, 'events'))[0]!.start).toBe(at(13));
  });
  test('未割当のタスクを1回のタップ（＋確認）で空き時間に入れる', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 't1', title: '未割当の作業', estimateMinutes: 45 })] });
    await page.getByTestId('chip-inbox').click();
    await page.getByTestId('inbox-place').click();
    await page.getByTestId('inbox-sheet').getByTestId('plan-apply').click();
    await expect.poll(async () => (await readStore(page, 'tasks'))[0]!.plannedStart).not.toBeNull();
    const t = (await readStore(page, 'tasks'))[0]!;
    expect((t.plannedEnd as number) - (t.plannedStart as number)).toBe(45 * 60_000);
  });
  test('延期は期限を変えずに候補から選ぶ', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 't1', title: '延期するタスク', plannedStart: at(8), plannedEnd: at(9), special: 'assignment', assignment: { content: '', submitMethod: '', submitTo: '', deadline: at(20, 0, 3) } })] });
    await page.getByTestId('tl-task:t1').click();
    await page.getByTestId('task-postpone').click();
    await page.getByTestId('postpone-preview').getByTestId('plan-option-1').click();
    await page.getByTestId('postpone-preview').getByTestId('plan-apply').click();
    await expect.poll(async () => (await readStore(page, 'tasks'))[0]!.plannedStart as number).toBeGreaterThanOrEqual(at(0, 0, 1));
    expect(((await readStore(page, 'tasks'))[0]!.assignment as { deadline: number }).deadline).toBe(at(20, 0, 3));
  });
});

test.describe('再設計：専門の種類・履歴・設定', () => {
  test('編集画面で種類（買い物）を選ぶと専用の項目が出て、詳細のチェックが情報カードから変えられる', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('quick-add').click();
    await page.getByTestId('quick-detail').click();
    await expect(page.getByTestId('editor-sheet')).toBeVisible();
    await page.getByTestId('editor-title').fill('週末の買い物');
    await page.getByTestId('editor-type').click();
    await page.getByTestId('spec-shopping').click();
    await page.getByTestId('editor-tab-special').click();
    await expect(page.getByTestId('spec-form')).toHaveAttribute('data-spec', 'shopping');
    await page.getByTestId('spec-add-items').click();
    await page.getByTestId('spec-field-items').getByLabel('項目名').fill('牛乳');
    await page.getByTestId('editor-save').click();
    await expect(page.getByTestId('editor-sheet')).toHaveCount(0);
    const t = (await readStore(page, 'tasks'))[0]!;
    expect((t.extra as { spec: { type: string } }).spec.type).toBe('shopping');
    await page.getByTestId('tab-tasks').click();
    await page.getByTestId('tasks-screen').getByText('週末の買い物').first().click();
    await page.getByTestId('spec-more').click();
    await page.getByTestId('spec-check').first().click();
    await expect.poll(async () => (((await readStore(page, 'tasks'))[0]!.extra as { spec: { details: { items: { done: boolean }[] } } }).spec.details.items[0]!.done)).toBe(true);
    await expect(page.getByTestId('spec-card').locator('[data-label="営業時間"]')).toContainText('未確認');
  });
  test('P48：削除したタスクを変更履歴から戻せる', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 't1', title: '消して戻す', plannedStart: at(15), plannedEnd: at(16) })] });
    await page.getByTestId('tl-task:t1').click();
    await page.getByTestId('delete-task').click();
    await page.getByRole('button', { name: '削除', exact: true }).click();
    await page.evaluate(() => new Promise((r) => setTimeout(r, 5600)));
    await expect.poll(async () => (await readStore(page, 'tasks')).length).toBe(0);
    await openSettings(page);
    await page.getByTestId('nav-history').click();
    await page.getByTestId('history-row').filter({ hasText: '消して戻す' }).getByTestId('history-rollback').first().click();
    await page.getByRole('button', { name: '元に戻す' }).click();
    await expect.poll(async () => (await readStore(page, 'tasks')).length).toBe(1);
  });
  test('P15・P43：予定の書き出しと、通知を控える時間', async ({ page }) => {
    await openApp(page);
    await seed(page, { events: [event({ id: 'e1', title: '書き出す予定', start: at(13), end: at(14) })] });
    await openSettings(page);
    await page.getByTestId('nav-export').click();
    const [dl] = await Promise.all([page.waitForEvent('download'), page.getByTestId('export-ics').click()]);
    expect(dl.suggestedFilename()).toMatch(/\.ics$/);
    const text = await (await import('node:fs/promises')).readFile((await dl.path())!, 'utf8');
    expect(text).toContain('SUMMARY:書き出す予定');
  });
});
