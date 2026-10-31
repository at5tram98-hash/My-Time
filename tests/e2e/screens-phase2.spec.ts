import { expect, test, type Page } from '@playwright/test';
import { at, event, openApp, seed } from './helpers';
import { demo } from './demo';

/** Phase 2 のレビュー用画面キャプチャ（docs/screenshots/p2-*.png）。データはテスト用に投入したもの。 */
const OUT = 'docs/screenshots';
const shot = async (page: Page, name: string) => {
  await page.waitForTimeout(450);
  await page.screenshot({ path: `${OUT}/${name}.png` });
};

test.describe('画面キャプチャ Phase2', () => {
  test('初回セットアップ', async ({ page }) => {
    await page.goto('/');
    await expect(page.getByTestId('onboarding')).toBeVisible();
    await shot(page, 'p2-01-onboarding');
  });

  test('各画面', async ({ page }) => {
    await openApp(page);
    await seed(page, {
      ...demo,
      tasks: [
        ...demo.tasks,
        {
          ...demo.tasks[0], id: 'p1', title: '研究の課題', special: 'assignment', icon: '📄', plannedStart: null, plannedEnd: null, status: 'notStarted', intervals: [], actualStart: null, manualProgress: null,
          assignment: { content: '第4章の要約', submitMethod: 'Moodle', submitTo: '担当教員', deadline: at(23, 59, 3) }, sourceEventId: 'e1', sourceKey: 'class:e1:assignment:k', category: null,
        },
      ],
      events: [
        ...demo.events,
        event({ id: 'r1', title: 'ゼミ', calendarId: 'cal-class', start: at(16, 30, -7), end: at(18, 0, -7), recurrence: { freq: 'weekly', interval: 1, byWeekday: null, until: null } }),
      ],
    });

    // 授業の予定の編集（科目・教室・課題・小テスト）
    await page.getByRole('button', { name: /予定 マクロ経済学/ }).click();
    await page.getByTestId('add-assignment').click();
    await page.getByTestId('add-quiz').click();
    await shot(page, 'p2-02-class-event');
    await page.getByRole('button', { name: 'キャンセル' }).first().click();

    // 繰り返し予定の範囲選択
    await page.getByRole('button', { name: /予定 ゼミ/ }).click();
    await page.getByTestId('delete-event').click();
    await shot(page, 'p2-03-recurrence-scope');
    await page.getByRole('button', { name: 'キャンセル' }).last().click();
    await page.getByRole('button', { name: 'キャンセル' }).first().click();

    // 複数日コピー
    await page.getByRole('button', { name: /予定 GU アルバイト/ }).click();
    await page.getByTestId('copy-event').click();
    await page.getByTestId('copy-day-14-in').click();
    await page.getByTestId('copy-day-16-in').click();
    await shot(page, 'p2-04-copy-days');
    await page.getByRole('button', { name: 'キャンセル' }).last().click();
    await page.getByRole('button', { name: 'キャンセル' }).first().click();

    // タスク（未設定に入った課題）
    await page.getByTestId('tab-tasks').click();
    await shot(page, 'p2-05-tasks-unscheduled');

    // 分析
    await page.getByTestId('tab-analysis').click();
    await shot(page, 'p2-06-analysis');

    // その他・各管理画面・取り込み
    await page.getByTestId('tab-other').click();
    await shot(page, 'p2-07-other');
    await page.getByTestId('nav-calendars').click();
    await shot(page, 'p2-08-calendars');
    await page.getByTestId('back').click();
    await page.getByTestId('nav-import').click();
    await page.getByTestId('import-text').fill('10/14 18:00-20:00 ごはん @相手\n10/15 22:00-6:00 夜勤\n10/12 10:45-12:15 マクロ経済学');
    await page.getByTestId('analyze-import').click();
    await shot(page, 'p2-09-import');
  });
});
