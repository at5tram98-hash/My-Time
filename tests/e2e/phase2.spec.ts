import { expect, test, type Page } from '@playwright/test';
import { at, event, openApp, readStore, seed, task } from './helpers';

/** Phase 2 の画面操作（ローカルのみ。サーバー連携は fullstack.spec.ts） */

async function toOther(page: Page) {
  await page.getByTestId('tab-other').click();
  await expect(page.getByTestId('other-screen')).toBeVisible();
}

async function newEvent(page: Page) {
  await page.getByTestId('home-add').click();
  await page.getByRole('menuitem', { name: '新規予定' }).click();
  await expect(page.getByTestId('event-title-input')).toBeVisible();
}

/** 見出しで今のカードを確かめてから、そのカードのボタンを押す（切り替え中の誤タップを避ける） */
async function obStep(page: Page, heading: string, button: string) {
  const card = page.locator('.ob-card').filter({ has: page.getByRole('heading', { name: heading, exact: true }) });
  await expect(page.locator('.ob-card')).toHaveCount(1);
  await expect(card).toBeVisible();
  await page.waitForTimeout(450);
  await card.getByTestId(button).click();
  await expect(card).toHaveCount(0);
}

test.describe('Phase 2', () => {
  test('初回セットアップ：科目と勤務先を登録して使いはじめる', async ({ page }) => {
    // 時計を固定するとばねアニメーションが止まって見えるため、このテストだけ実時間で動かす
    await page.goto('/');
    await expect(page.getByTestId('onboarding')).toBeVisible();
    await obStep(page, 'My Time へようこそ', 'ob-next');
    await obStep(page, 'Googleでログイン', 'ob-next');
    await obStep(page, 'カレンダー', 'ob-next');
    await expect(page.locator('.ob-card')).toHaveCount(1);
    await page.getByTestId('ob-subjects').fill('財政学、マクロ経済学');
    await page.getByTestId('ob-employers').fill('GU');
    await expect(page.getByTestId('ob-subjects')).toHaveValue('財政学、マクロ経済学');
    await obStep(page, '授業と勤務先', 'ob-next');
    await obStep(page, '通知', 'ob-next');
    await obStep(page, '外観', 'ob-next');
    await obStep(page, '使い方', 'ob-finish');
    await expect(page.getByTestId('onboarding')).toHaveCount(0);
    expect((await readStore(page, 'subjects')).map((s) => s.name).sort()).toEqual(['マクロ経済学', '財政学']);
    expect((await readStore(page, 'employers')).map((s) => s.name)).toEqual(['GU']);
    await page.reload();
    await expect(page.getByTestId('home-screen')).toBeVisible();
    await expect(page.getByTestId('onboarding')).toHaveCount(0);
  });

  test('カレンダーを追加し、非表示にするとその予定が時間軸から消える', async ({ page }) => {
    await openApp(page);
    await toOther(page);
    await page.getByTestId('nav-calendars').click();
    await page.getByTestId('add-calendar').click();
    await page.getByTestId('calendar-editor').getByPlaceholder(/カレンダー/).fill('サークル');
    await page.getByTestId('save-calendar').click();
    const cals = await readStore(page, 'calendars');
    const circle = cals.find((c) => c.name === 'サークル');
    expect(circle).toBeTruthy();
    await seed(page, { events: [event({ id: 'e-circle', title: '練習', calendarId: circle!.id, start: at(15), end: at(16) })] });
    await expect(page.getByRole('button', { name: /予定 練習/ })).toBeVisible();
    await toOther(page);
    await page.getByTestId('nav-calendars').click();
    await page.getByTestId(`calendar-row-${circle!.id as string}`).getByRole('switch').click();
    await page.getByTestId('tab-home').click();
    await expect(page.getByRole('button', { name: /予定 練習/ })).toHaveCount(0);
  });

  test('授業の課題・小テストは確認してからタスク化し、再保存しても重複しない', async ({ page }) => {
    await openApp(page);
    await newEvent(page);
    await page.getByTestId('event-title-input').fill('財政学');
    await page.getByTestId('event-calendar').selectOption('cal-class');
    await page.getByTestId('event-start').fill('2026-10-12T13:00');
    await page.getByTestId('event-end').fill('2026-10-12T14:30');
    await expect(page.getByTestId('class-fields')).toBeVisible();
    await page.getByTestId('add-assignment').click();
    await page.getByTestId('add-quiz').click();
    await page.getByTestId('quiz-row').getByPlaceholder(/小テスト/).fill('第3回小テスト');
    await page.getByTestId('save-event').click();
    const dlg = page.getByRole('alertdialog');
    await expect(dlg).toContainText('課題・テスト対策のタスクを作成しますか？');
    await dlg.getByRole('button', { name: '作成', exact: true }).click();
    await expect(page.getByTestId('event-title-input')).toHaveCount(0);

    const made = (await readStore(page, 'tasks')).filter((t) => t.sourceEventId);
    expect(made.map((t) => t.special).sort()).toEqual(['assignment', 'testPrep']);
    expect(new Set(made.map((t) => t.sourceKey)).size).toBe(2);

    // 作業時間が未入力なので「未設定」に入る
    await page.getByTestId('tab-tasks').click();
    await expect(page.getByTestId('section-unscheduled')).toContainText('財政学の課題');

    // 同じ予定を開いて保存し直してもタスクは増えない（安定ID）
    await page.getByTestId('tab-home').click();
    await page.getByRole('button', { name: /予定 財政学/ }).click();
    await page.getByTestId('save-event').click();
    await expect(page.getByTestId('event-title-input')).toHaveCount(0);
    expect((await readStore(page, 'tasks')).filter((t) => t.sourceEventId).length).toBe(2);
  });

  test('繰り返し予定：「この予定のみ」削除は今回だけ、「これ以降」は系列を打ち切る', async ({ page }) => {
    await openApp(page);
    await seed(page, {
      events: [event({ id: 'wk', title: 'ゼミ', calendarId: 'cal-class', start: at(13, 0, -7), end: at(14, 0, -7), recurrence: { freq: 'weekly', interval: 1, byWeekday: null, until: null } })],
    });
    await page.getByRole('button', { name: /予定 ゼミ/ }).click();
    await page.getByRole('button', { name: '削除' }).click();
    await expect(page.getByRole('dialog').or(page.getByRole('alertdialog')).last()).toContainText('繰り返しの予定を削除します');
    await page.getByRole('button', { name: 'この予定のみ' }).click();
    await expect(page.getByRole('button', { name: /予定 ゼミ/ })).toHaveCount(0);
    let wk = (await readStore(page, 'events')).find((e) => e.id === 'wk')!;
    expect(wk.exceptions).toEqual([expect.objectContaining({ originalStart: at(13), kind: 'cancelled' })]);

    // 翌週の回は残っている → 「これ以降」で削除すると系列が打ち切られ、過去の回は残る
    await page.clock.setFixedTime(at(10, 0, 7));
    await page.reload();
    await expect(page.getByRole('button', { name: /予定 ゼミ/ })).toBeVisible();
    await page.getByRole('button', { name: /予定 ゼミ/ }).click();
    await page.getByRole('button', { name: '削除' }).click();
    await page.getByRole('button', { name: 'これ以降のすべての予定' }).click();
    await expect(page.getByRole('button', { name: /予定 ゼミ/ })).toHaveCount(0);
    wk = (await readStore(page, 'events')).find((e) => e.id === 'wk')!;
    expect((wk.recurrence as { until: number }).until).toBeLessThan(at(13, 0, 7));
    expect((wk.recurrence as { until: number }).until).toBeGreaterThanOrEqual(at(13, 0, -7));
  });

  test('ミニカレンダーで複数日を選んで予定をコピーする', async ({ page }) => {
    await openApp(page);
    await seed(page, { events: [event({ id: 'sh', title: 'シフト', calendarId: 'cal-job', start: at(17), end: at(21) })] });
    await page.getByRole('button', { name: /予定 シフト/ }).click();
    await page.getByRole('button', { name: '別の日にコピー' }).click();
    await expect(page.getByTestId('mini-cal')).toBeVisible();
    await page.getByTestId('copy-day-14-in').click();
    await page.getByTestId('copy-day-16-in').click();
    await page.getByTestId('apply-copy').click();
    await expect(page.getByTestId('mini-cal')).toHaveCount(0);
    const copies = (await readStore(page, 'events')).filter((e) => e.title === 'シフト').map((e) => e.start).sort();
    expect(copies).toEqual([at(17), at(17, 0, 2), at(17, 0, 4)]);
  });

  test('テキスト取り込み：1件ずつスキップでき、選んだものだけ追加される', async ({ page }) => {
    await openApp(page);
    await toOther(page);
    await page.getByTestId('nav-import').click();
    await page.getByTestId('import-text').fill('10/14 18:00-20:00 ごはん @相手\n10/15 22:00-6:00 夜勤');
    await page.getByTestId('analyze-import').click();
    await expect(page.getByTestId('import-item')).toHaveCount(2);
    await page.getByTestId('import-item').nth(0).getByRole('radio', { name: 'スキップ' }).click();
    await page.getByTestId('apply-import').click();
    await expect(page.getByTestId('import-list')).toHaveCount(0);
    const evs = (await readStore(page, 'events')).filter((e) => e.source);
    expect(evs.map((e) => e.title)).toEqual(['夜勤']);
    expect(evs[0]!.end).toBe(at(6, 0, 4)); // 日付をまたぐ
  });

  test('自動予約：開始予約の時刻を過ぎるとタスクが自動で開始される', async ({ page }) => {
    await openApp(page);
    await seed(page, { tasks: [task({ id: 'ar', title: '英単語', plannedStart: at(11), plannedEnd: at(11, 30) })] });
    await page.locator('[data-task-title="英単語"]').first().click();
    await page.getByRole('button', { name: /開始/ }).first().click({ delay: 700 });
    await page.getByTestId('ar-start').fill('2026-10-12T10:45');
    await page.getByTestId('save-ar').click();
    expect((await readStore(page, 'tasks')).find((t) => t.id === 'ar')!.autoStartAt).toBe(at(10, 45));
    await page.clock.setFixedTime(at(10, 50));
    await page.reload();
    await expect.poll(async () => (await readStore(page, 'tasks')).find((t) => t.id === 'ar')!.status).toBe('running');
    const t = (await readStore(page, 'tasks')).find((x) => x.id === 'ar')!;
    expect(t.actualStart).toBe(at(10, 45));
  });

  test('分析：完了率・遅延率・実行時間を表示し、週を移動できる', async ({ page }) => {
    await openApp(page);
    await seed(page, {
      tasks: [
        task({ id: 'a1', title: '完了（遅れ）', plannedStart: at(8), plannedEnd: at(9), status: 'done', actualStart: at(8, 10), actualEnd: at(9, 20), intervals: [{ start: at(8, 10), end: at(9, 20) }] }),
        task({ id: 'a2', title: '未完了', plannedStart: at(9, 30), plannedEnd: at(10) }),
      ],
    });
    await page.getByTestId('tab-analysis').click();
    await expect(page.getByTestId('tile-completion')).toContainText('50');
    await expect(page.getByTestId('tile-completion')).toContainText('1 / 2 件');
    await expect(page.getByTestId('tile-work')).toContainText('1時間10分');
    const label = await page.getByTestId('week-label').textContent();
    await page.getByTestId('prev-week').click();
    await expect(page.getByTestId('week-label')).not.toHaveText(label!);
  });

  test('サーバー未接続でも「その他」は落ちずに状態を表示する', async ({ page }) => {
    await openApp(page);
    await toOther(page);
    await expect(page.getByTestId('sync-status')).toBeVisible();
    await page.getByTestId('nav-backups').click();
    await expect(page.getByText(/ログイン|未設定|接続/).first()).toBeVisible();
  });
});
