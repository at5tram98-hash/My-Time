import { describe, expect, it } from 'vitest';
import { clampScroll, edgeScrollSpeed } from './edgeScroll';

describe('ドラッグ中の端の自動スクロール', () => {
  it('中央では動かず、端に近いほど速い（上は負・下は正）', () => {
    expect(edgeScrollSpeed(400, 100, 800)).toBe(0);
    expect(edgeScrollSpeed(150, 100, 800)).toBeLessThan(0);
    expect(edgeScrollSpeed(105, 100, 800)).toBeLessThan(edgeScrollSpeed(150, 100, 800));
    expect(edgeScrollSpeed(795, 100, 800)).toBeGreaterThan(edgeScrollSpeed(750, 100, 800));
  });
  it('領域の外まで指が出ても上限で止まる', () => {
    expect(edgeScrollSpeed(2000, 100, 800)).toBe(14);
    expect(edgeScrollSpeed(-500, 100, 800)).toBe(-14);
  });
  it('小さい領域では使わない', () => {
    expect(edgeScrollSpeed(105, 100, 200)).toBe(0);
  });
  it('スクロールの端では止まる', () => {
    expect(clampScroll(-10, 4, 1000)).toBe(-4);
    expect(clampScroll(10, 995, 1000)).toBe(5);
    expect(clampScroll(10, 1000, 1000)).toBe(0);
  });
});
