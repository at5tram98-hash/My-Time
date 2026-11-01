import { describe, expect, it } from 'vitest';
import { convertUnit, formatValue, searchParts, studioImpact, studioProgress, type StudioField } from './index';

const f = (id: string, type: StudioField['type'], extra: Partial<StudioField> = {}): StudioField => ({ id, type, label: id, showInInfo: true, sectionId: 's', ...extra });

describe('Create Studio の単位と進捗', () => {
  it('60分↔1時間など同じ次元だけ換算し、異なる単位は変えない', () => {
    expect(convertUnit(60, 'min', 'hour')).toBe(1);
    expect(convertUnit(1.5, 'hour', 'min')).toBe(90);
    expect(convertUnit(3, 'page', 'min')).toBeNull();
    expect(convertUnit(3, 'times', 'piece')).toBeNull();
    expect(convertUnit(3, 'custom:問', 'custom:問')).toBe(3);
  });
  it('20/30ページ、5/8項目、45/120分の進捗', () => {
    const pages = { fields: [f('p', 'number', { unit: 'page' })], progress: { mode: 'number' as const, fieldId: 'p', target: 30 } };
    expect(studioProgress(pages, { p: 20 })).toMatchObject({ value: 20 / 30, label: '20/30ページ', over: false });
    const checks = { fields: Array.from({ length: 8 }, (_, i) => f(`c${i}`, 'check')), progress: { mode: 'checklist' as const, fieldId: null, target: null } };
    const vals = Object.fromEntries(Array.from({ length: 5 }, (_, i) => [`c${i}`, true]));
    expect(studioProgress(checks, vals)).toMatchObject({ value: 5 / 8, label: '5/8項目' });
    const time = { fields: [], progress: { mode: 'time' as const, fieldId: null, target: 120 } };
    expect(studioProgress(time, {}, 45)).toMatchObject({ value: 45 / 120, label: '45/120分' });
  });
  it('分母0・目標超過・負値・数値でない値でも壊れない', () => {
    const t = { fields: [f('p', 'number')], progress: { mode: 'number' as const, fieldId: 'p', target: 0 } };
    expect(studioProgress(t, { p: 5 }).value).toBeNull();
    const t2 = { ...t, progress: { ...t.progress, target: 10 } };
    expect(studioProgress(t2, { p: 15 })).toMatchObject({ value: 1, over: true });
    expect(studioProgress(t2, { p: -3 }).value).toBe(0);
    expect(studioProgress(t2, { p: 'abc' }).value).toBe(0);
  });
  it('金額の表示と部品検索', () => {
    expect(formatValue({ unit: 'yen', precision: 0 }, 1200)).toBe('1,200円');
    expect(searchParts('実行時間').map((p) => p.type)).toContain('worktime');
    expect(searchParts('時給').map((p) => p.type)).toContain('number');
  });
  it('項目の削除・型変更の影響件数（値の入っている記録だけ数える）', () => {
    const prev = { fields: [f('a', 'text'), f('b', 'number')] };
    const next = { fields: [f('b', 'text')] };
    const r = studioImpact(prev, next, [{ values: { a: 'x' } }, { values: { b: 1 } }, { values: {} }]);
    expect(r.removed.map((x) => x.id)).toEqual(['a']);
    expect(r.retyped.map((x) => x.id)).toEqual(['b']);
    expect(r.affected).toBe(2);
  });
});
