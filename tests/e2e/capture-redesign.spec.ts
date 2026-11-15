import { expect, test, type Page } from '@playwright/test';
import { at, event, openApp, seed, task } from './helpers';

/** 再設計（2026-11）のレビュー用画像。docs/screenshots/redesign/ に保存（画面キャプチャ：CI の合否には含めない） */
const DIR = 'docs/screenshots/redesign';

export async function seedRedesign(page: Page) {
  await seed(page, {
    events: [
      event({ id: 'cls', title: '経済学', calendarId: 'cal-class', start: at(13), end: at(14, 30), classInfo: { subjectId: null, subjectName: '経済学', room: '3-201', assignments: [], quizzes: [] }, extra: { place: { name: '大学', address: '', lat: null, lng: null } } }),
      event({ id: 'job', title: 'GU 勤務', calendarId: 'cal-job', start: at(18, 30), end: at(22), extra: { travelMinutes: 25, place: { name: 'GU 駅前店', address: '', lat: null, lng: null }, spec: { type: 'shift', details: { workplace: 'GU', hourlyWage: 1300, breakMinutes: 0, transportFee: 300 } } } }),
      event({ id: 'mtg', title: 'ゼミの打ち合わせ', calendarId: 'cal-general', start: at(14), end: at(15) }),
      event({ id: 'trip', title: '京都旅行', calendarId: 'cal-general', start: at(9, 0, 5), end: at(19, 0, 6), extra: { spec: { type: 'trip', details: { packing: [{ id: '1', name: '充電器', done: true }, { id: '2', name: '着替え', done: false }] } } } }),
    ],
    tasks: [
      task({ id: 'run', title: '統計のレポート', plannedStart: at(10), plannedEnd: at(11, 30), status: 'running', actualStart: at(10), intervals: [{ start: at(10), end: null }], estimateMinutes: 90, manualProgress: { value: 0.4, at: at(10, 30), workedMsAtSample: 30 * 60_000 }, extra: { spec: { type: 'assignment', details: {} } } }),
      task({ id: 'shop', title: '買い物', plannedStart: at(15, 30), plannedEnd: at(16), icon: 'cart', extra: { spec: { type: 'shopping', details: { items: [{ id: 'a', name: '牛乳', done: false }, { id: 'b', name: '洗剤', done: true }] } } } }),
      task({ id: 'prep', title: '出勤の準備', plannedStart: at(17, 45), plannedEnd: at(18, 5), sourceEventId: 'job', icon: 'person' }),
      task({ id: 'chk', title: '奨学金の書類を確認', kind: 'check', checkAt: at(12), icon: 'note' }),
      task({ id: 'inbox1', title: '英語の小テスト対策', estimateMinutes: 120, extra: { spec: { type: 'exam', details: { examAt: at(9, 0, 2) } } } }),
      task({ id: 'inbox2', title: '経済学の課題', estimateMinutes: 600, special: 'assignment', assignment: { content: '', submitMethod: '', submitTo: '', deadline: at(23, 59) } }),
    ],
  });
}

test.describe('画面キャプチャ（再設計）', () => {
  for (const theme of ['light', 'dark'] as const) {
    test(`今日・追加・気づいたこと・未割当・詳細・振り返り（${theme}）`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: theme });
      await openApp(page);
      await seedRedesign(page);
      await page.waitForTimeout(400);
      await page.screenshot({ path: `${DIR}/${theme}-01-today.png` });

      await page.getByTestId('quick-add').click();
      await page.getByTestId('quick-input').fill('土曜日はGU 18:30〜22:00、時給1,300円\n金曜までに経済学のレポート、2時間ぐらい\n17時に出かける');
      await expect(page.getByTestId('quick-candidate')).toHaveCount(3);
      await page.waitForTimeout(1200);
      await page.screenshot({ path: `${DIR}/${theme}-02-quick-add.png` });
      await page.getByRole('button', { name: 'キャンセル' }).first().click();
      const discard = page.getByRole('button', { name: '変更を破棄' });
      if (await discard.isVisible().catch(() => false)) await discard.click();

      await page.getByTestId('chip-issues').click();
      await expect(page.getByTestId('issues-sheet')).toBeVisible();
      await page.getByTestId('issue-card').first().locator('.issue-head').click();
      await page.waitForTimeout(400);
      await page.screenshot({ path: `${DIR}/${theme}-03-issues.png` });
      await page.getByTestId('issues-sheet').getByRole('button', { name: '完了' }).click();

      await page.getByTestId('chip-inbox').click();
      await expect(page.getByTestId('inbox-sheet')).toBeVisible();
      await page.waitForTimeout(400);
      await page.screenshot({ path: `${DIR}/${theme}-04-inbox.png` });
      await page.getByTestId('inbox-sheet').getByRole('button', { name: '完了' }).click();

      await page.getByTestId('tl-event:job').click();
      await expect(page.getByTestId('event-info')).toBeVisible();
      await page.waitForTimeout(400);
      await page.screenshot({ path: `${DIR}/${theme}-05-shift-info.png` });
      await page.getByTestId('event-info').getByRole('button', { name: '閉じる' }).click();

      await page.getByTestId('tab-analysis').click();
      await page.getByTestId('planning-insights').scrollIntoViewIfNeeded();
      await page.waitForTimeout(300);
      await page.screenshot({ path: `${DIR}/${theme}-06-review.png` });

      await page.getByTestId('tab-home').click();
      await page.getByTestId('open-settings').click();
      await expect(page.getByTestId('settings-push')).toBeVisible();
      await page.waitForTimeout(500);
      await page.screenshot({ path: `${DIR}/${theme}-07-settings.png` });
    });
  }

  test('種類から選ぶ・320px・特大文字', async ({ page }) => {
    await openApp(page);
    await seedRedesign(page);
    await page.getByTestId('quick-add').click();
    await page.getByTestId('quick-types').click();
    await expect(page.getByTestId('spec-type-popup')).toBeVisible();
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${DIR}/light-08-types.png` });
    await page.setViewportSize({ width: 320, height: 568 });
    await page.keyboard.press('Escape');
    await page.keyboard.press('Escape');
    await page.reload();
    await expect(page.getByTestId('home-screen')).toBeVisible();
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${DIR}/light-09-today-320.png` });
  });
});
