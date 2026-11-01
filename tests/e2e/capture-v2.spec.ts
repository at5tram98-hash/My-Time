import { expect, test, type Page } from '@playwright/test';
import { openApp, seed } from './helpers';
import { demo } from './demo';

/** UI/UX v2 のレビュー用キャプチャ（docs/screenshots/v2）。通常の E2E からは除外（--grep-invert 画面キャプチャ） */
const OUT = 'docs/screenshots/v2';
const shot = async (page: Page, name: string) => { await page.waitForTimeout(450); await page.screenshot({ path: `${OUT}/${test.info().project.name}-${name}.png` }); };

test.describe('画面キャプチャ v2', () => {
  for (const scheme of ['light', 'dark'] as const) {
    test(`主要画面（${scheme}）`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: scheme });
      await openApp(page);
      await seed(page, demo);
      await shot(page, `${scheme}-home`);
      for (const t of ['calendar', 'tasks', 'analysis', 'other'] as const) {
        await page.getByTestId(`tab-${t}`).click();
        await shot(page, `${scheme}-${t}`);
      }
      await page.getByTestId('tab-home').click();
      await page.getByTestId('home-add').click();
      await expect(page.getByTestId('editor-sheet')).toBeVisible();
      await shot(page, `${scheme}-editor-basic`);
      await page.getByTestId('editor-tab-option').click();
      await shot(page, `${scheme}-editor-option`);
      await page.keyboard.press('Escape');
      await page.waitForTimeout(400);
      await page.getByTestId('task-row-t2').getByRole('button').first().click();
      await shot(page, `${scheme}-task-info`);
    });
  }
});

test('画面キャプチャ v2 Studio', async ({ page }) => {
  await openApp(page);
  await seed(page, demo);
  await page.getByTestId('tab-other').click();
  await page.getByTestId('nav-studio').click();
  await shot(page, 'studio-list');
  await page.getByTestId('studio-new-task').click();
  await page.getByTestId('studio-name').fill('読書');
  await page.getByTestId('studio-part-search').fill('ページ');
  await shot(page, 'studio-search');
  await page.locator('[data-testid^="part-"]').first().click();
  await shot(page, 'studio-field');
  await page.getByTestId('field-editor').getByRole('button', { name: '追加' }).click();
  await page.getByTestId('studio-part-search').fill('メモ');
  await page.locator('[data-testid^="part-"]').first().click();
  await page.getByTestId('field-editor').getByRole('button', { name: '追加' }).click();
  await page.getByTestId('progress-number').click();
  await page.getByTestId('progress-target').fill('300');
  await shot(page, 'studio-designer');
  await page.getByTestId('studio-preview').click();
  await shot(page, 'studio-preview');
  await page.keyboard.press('Escape');
  await page.getByTestId('studio-save').click();
  await expect(page.getByTestId('studio-card-読書')).toBeVisible();
  await shot(page, 'studio-saved');
  await page.getByTestId('tab-home').click();
  await page.getByTestId('home-add').click();
  await page.getByTestId('editor-type').click();
  await page.locator('[data-testid^="type-studio-"]').first().click();
  await page.getByTestId('editor-tab-special').click();
  await shot(page, 'studio-editor-special');
});
