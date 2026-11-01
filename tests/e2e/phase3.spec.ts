import { expect, test, type Page } from '@playwright/test';
import { at, openApp, readStore, seed, task } from './helpers';

/** 絵文字・絵文字風の記号（アプリが表示するアイコンとして出てはいけないもの） */
const EMOJI = /[\p{Extended_Pictographic}←-⇿›✓✔]/u;

/** 画面に見えている文字のうち、ユーザーが入力した本文（タイトル・メモ）以外に絵文字がないこと */
async function appIconText(page: Page): Promise<string> {
  return page.evaluate(() => {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const out: string[] = [];
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const el = n.parentElement;
      if (!el || el.closest('[data-user-text], .task-row-title, .tl-title, .fcard-title, .detail-title, .row-label, input, textarea')) continue;
      if (el.closest('[hidden]')) continue;
      out.push(n.textContent ?? '');
    }
    return out.join('');
  });
}

test.describe('Phase 3：アイコン刷新と旧データ互換', () => {
  test('旧形式の絵文字・未知の値のタスクも SVG で表示し、保存値は書き換えない。再選択で新しい ID を保存', async ({ page }) => {
    await openApp(page);
    await seed(page, {
      tasks: [
        task({ id: 'legacy', title: '旧アイコンのタスク', icon: '🧪', plannedStart: at(13), plannedEnd: at(14) }),
        task({ id: 'unknown', title: '未知のアイコン 🦄 タイトルの絵文字は残す', icon: '🦄', plannedStart: at(15), plannedEnd: at(16) }),
        task({ id: 'modern', title: '新しいID', icon: 'star', plannedStart: at(17), plannedEnd: at(18) }),
      ],
    });
    const row = (id: string) => page.getByTestId(`task-row-${id}`);
    await expect(row('legacy').locator('[data-icon]').first()).toHaveAttribute('data-icon', 'flask');
    await expect(row('legacy').locator('[data-icon]').first()).toHaveAttribute('data-icon-source', 'legacy');
    await expect(row('unknown').locator('[data-icon]').first()).toHaveAttribute('data-icon', 'circle');
    await expect(row('modern').locator('[data-icon]').first()).toHaveAttribute('data-icon-source', 'id');
    // ユーザーが入力したタイトルの絵文字は残す
    await expect(row('unknown')).toContainText('🦄');

    for (const t of ['home', 'calendar', 'tasks', 'analysis', 'other'] as const) {
      await page.getByTestId(`tab-${t}`).click();
      await page.waitForTimeout(200);
      expect(EMOJI.test(await appIconText(page)), `${t} にアイコンとしての絵文字がない`).toBe(false);
    }
    await page.getByTestId('tab-home').click();

    // 変更せずに保存しても元の値のまま
    await row('unknown').getByRole('button').first().click();
    await page.getByRole('button', { name: '編集', exact: true }).click();
    await expect(page.getByRole('radiogroup', { name: 'アイコン' }).getByRole('radio', { checked: true })).toHaveCount(0);
    await page.getByTestId('save-task').click();
    await expect.poll(async () => (await readStore(page, 'tasks')).find((t) => t.id === 'unknown')?.icon).toBe('🦄');
    await page.keyboard.press('Escape');

    // 旧値は対応するアイコンが選択済みとして表示され、別のアイコンを選ぶと新しい ID を保存
    await row('legacy').getByRole('button').first().click();
    await page.getByRole('button', { name: '編集', exact: true }).click();
    const group = page.getByRole('radiogroup', { name: 'アイコン' });
    await expect(group.getByRole('radio', { name: '実験' })).toHaveAttribute('aria-checked', 'true');
    expect(EMOJI.test((await group.textContent()) ?? '')).toBe(false);
    await group.getByRole('radio', { name: '目標' }).click();
    await expect(group.getByRole('radio', { name: '目標' })).toHaveAttribute('aria-checked', 'true');
    await page.getByTestId('save-task').click();
    await expect.poll(async () => (await readStore(page, 'tasks')).find((t) => t.id === 'legacy')?.icon).toBe('target');
    // 他の記録は一括で書き換えていない
    const all = await readStore(page, 'tasks');
    expect(all.find((t) => t.id === 'unknown')?.icon).toBe('🦄');
    expect(all.find((t) => t.id === 'modern')?.icon).toBe('star');
  });

  test('新規タスクの既定アイコンは ID で保存する', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('home-add').click();
    await page.getByRole('menuitem', { name: '新規タスク' }).click();
    await page.getByTestId('task-title-input').fill('新規');
    await page.getByTestId('save-task').click();
    await expect.poll(async () => (await readStore(page, 'tasks')).find((t) => t.title === '新規')?.icon).toBe('book');
  });
});

test.describe('Phase 3：タブバー', () => {
  test('5タブの順番・名前・選択状態（色以外も）・44px 以上・素早い連続切替', async ({ page }) => {
    await openApp(page);
    const tabs = page.getByTestId('tabbar').getByRole('button');
    await expect(tabs).toHaveText(['ホーム', 'カレンダー', 'タスク', '分析', 'その他']);
    for (const b of await tabs.all()) {
      const box = (await b.boundingBox())!;
      expect(box.height).toBeGreaterThanOrEqual(44);
      expect(box.width).toBeGreaterThanOrEqual(44);
    }
    // 素早い連続切替：最後に押したタブが選ばれ、画面も一致する
    for (const t of ['calendar', 'tasks', 'analysis', 'other', 'home', 'tasks'] as const) await page.getByTestId(`tab-${t}`).click({ delay: 0 });
    await expect(page.getByTestId('tab-tasks')).toHaveAttribute('aria-current', 'page');
    await expect(page.locator('[aria-current="page"]')).toHaveCount(1);
    // 選択中はラベルが太字（色だけに頼らない）・カプセルが選択タブの位置へ
    const weight = (id: string) => page.getByTestId(`tab-${id}`).locator('.tab-label').evaluate((el) => Number(getComputedStyle(el).fontWeight));
    expect(await weight('tasks')).toBeGreaterThan(await weight('home'));
    await expect.poll(async () => {
      const cap = (await page.locator('.tab-capsule').boundingBox())!;
      const tab = (await page.getByTestId('tab-tasks').boundingBox())!;
      return Math.abs(cap.x + cap.width / 2 - (tab.x + tab.width / 2));
    }).toBeLessThan(2);
  });

  test('最下部の内容はタブバーに隠れずに操作でき、シートを開くとタブバーより前に出る', async ({ page }) => {
    await openApp(page);
    await page.getByTestId('tab-other').click();
    const body = page.locator('.tab-panel:not([hidden]) .scroll-body').first();
    await body.evaluate((el) => el.scrollTo(0, el.scrollHeight));
    await page.waitForTimeout(200);
    const lastBtn = body.getByRole('button').last();
    const box = (await lastBtn.boundingBox())!;
    const bar = (await page.locator('.tabbar-glass').boundingBox())!;
    expect(box.y + box.height).toBeLessThanOrEqual(bar.y + 1);
    // シートを開くと、タブの位置にはシート（または背景）が来る
    await page.getByTestId('tab-home').click();
    await page.getByTestId('home-add').click();
    await page.getByRole('menuitem', { name: '新規タスク' }).click();
    await page.waitForTimeout(500);
    const hit = await page.evaluate(({ x, y }) => document.elementFromPoint(x, y)?.closest('.tabbar') != null, { x: bar.x + bar.width / 2, y: bar.y + bar.height / 2 });
    expect(hit).toBe(false);
  });

  for (const size of [{ width: 320, height: 568 }, { width: 852, height: 393 }]) {
    test(`ラベルが切れない（${size.width}×${size.height}・大きな文字）`, async ({ page }) => {
      await openApp(page);
      await page.setViewportSize(size);
      await page.evaluate(() => { document.documentElement.setAttribute('data-text-size', 'xlarge'); document.documentElement.style.setProperty('--base-size', '22px'); });
      await page.waitForTimeout(200);
      const clipped = await page.locator('.tab-label').evaluateAll((els) => els.filter((e) => e.scrollWidth > e.clientWidth + 1).map((e) => e.textContent));
      expect(clipped).toEqual([]);
      const bar = (await page.locator('.tabbar-glass').boundingBox())!;
      expect(bar.x).toBeGreaterThanOrEqual(0);
      expect(bar.x + bar.width).toBeLessThanOrEqual(size.width);
      expect(bar.y + bar.height).toBeLessThanOrEqual(size.height);
    });
  }

  test('動きを減らす設定ではカプセルを移動アニメーションさせない', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await openApp(page);
    const dur = await page.locator('.tab-capsule').evaluate((el) => getComputedStyle(el).transitionDuration);
    expect(dur.split(',').every((d) => parseFloat(d) < 0.01)).toBe(true); // 0s、または全体設定の 0.001ms
  });
});
