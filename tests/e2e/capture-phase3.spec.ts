import { expect, test, type Page } from '@playwright/test';
import { openApp, seed } from './helpers';
import { demo } from './demo';

/**
 * Phase 3 レビュー用の画面キャプチャ（docs/screenshots/phase3 に保存）。
 * データはテスト用に投入した架空のもの（旧形式の絵文字アイコン値を含む）。通常の E2E からは除外（--grep-invert 画面キャプチャ）。
 */
const OUT = 'docs/screenshots/phase3';

async function shoot(page: Page, name: string) {
  await page.waitForTimeout(450);
  await page.screenshot({ path: `${OUT}/${test.info().project.name}-${name}.png` });
}

async function allTabs(page: Page, prefix: string) {
  await shoot(page, `${prefix}-home`);
  for (const t of ['calendar', 'tasks', 'analysis', 'other'] as const) {
    await page.getByTestId(`tab-${t}`).click();
    await shoot(page, `${prefix}-${t}`);
  }
  await page.getByTestId('tab-home').click();
}

test.describe('画面キャプチャ Phase 3', () => {
  for (const scheme of ['light', 'dark'] as const) {
    test(`全タブ・アイコン選択（${scheme}）`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: scheme });
      await openApp(page);
      await seed(page, demo);
      await allTabs(page, scheme);
      // タブバーの拡大（月表示の密な背景の上）
      await page.getByTestId('tab-calendar').click();
      await page.getByTestId('view-menu').click();
      await page.getByRole('menuitemradio', { name: '月' }).click();
      await page.waitForTimeout(700);
      const bar = page.getByTestId('tabbar');
      const box = (await bar.boundingBox())!;
      await page.screenshot({ path: `${OUT}/${test.info().project.name}-${scheme}-tabbar.png`, clip: { x: 0, y: box.y - 40, width: 393, height: box.height + 60 } });
      await page.getByTestId('tab-home').click();
      // タスクのアイコン選択
      await page.getByTestId('home-add').click();
      await page.getByRole('menuitem', { name: '新規タスク' }).click();
      await expect(page.getByRole('radiogroup', { name: 'アイコン' })).toBeVisible();
      await page.getByRole('radiogroup', { name: 'アイコン' }).scrollIntoViewIfNeeded();
      await shoot(page, `${scheme}-task-icon-picker`);
    });
  }

  test('小型画面・横向き・文字拡大', async ({ page }) => {
    await openApp(page);
    await seed(page, demo);
    await page.setViewportSize({ width: 320, height: 568 });
    await shoot(page, 'small-home');
    await page.getByTestId('tab-tasks').click();
    await shoot(page, 'small-tasks');
    await page.setViewportSize({ width: 852, height: 393 });
    await page.getByTestId('tab-calendar').click();
    await shoot(page, 'landscape-calendar');
    await page.setViewportSize({ width: 393, height: 852 });
    await page.evaluate(() => document.documentElement.setAttribute('data-text-size', 'xlarge'));
    await page.evaluate(() => document.documentElement.style.setProperty('--base-size', '22px'));
    await page.getByTestId('tab-other').click();
    await shoot(page, 'xlarge-other');
  });
});
