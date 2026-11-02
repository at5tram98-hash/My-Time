import { beforeAll, describe, expect, it } from 'vitest';
import { fromWall, HOUR, makeTask, periodRange, periodStats, setDomainTimeZone, shiftPeriod, periodLabel } from './index';

beforeAll(() => setDomainTimeZone('Asia/Tokyo'));

describe('分析の期間集計（v2）', () => {
  it('日・週・月・年の範囲と前後移動', () => {
    const a = fromWall(2026, 10, 4, 15); // 2026-11-04(水)
    expect(periodRange('week', a).from).toBe(fromWall(2026, 10, 1));
    expect(periodRange('month', a)).toMatchObject({ from: fromWall(2026, 10, 1), to: fromWall(2026, 11, 1) });
    expect(shiftPeriod(periodRange('month', a), 1).to).toBe(fromWall(2027, 0, 1));
    expect(periodRange('year', a).to).toBe(fromWall(2027, 0, 1));
    expect(periodLabel(periodRange('month', a))).toBe('2026年11月');
  });
  it('複数日にまたがるタスクを二重に数えず、作業時間は実施した日に振り分ける', () => {
    const now = fromWall(2026, 10, 10);
    const t = makeTask({ title: 'A', kind: 'do', plannedStart: fromWall(2026, 10, 2, 22), plannedEnd: fromWall(2026, 10, 3, 2), status: 'done', actualEnd: fromWall(2026, 10, 3, 3), intervals: [{ start: fromWall(2026, 10, 2, 23), end: fromWall(2026, 10, 3, 1) }, { start: fromWall(2026, 10, 3, 2), end: fromWall(2026, 10, 3, 3) }] }, now);
    const w = periodStats([t], periodRange('week', fromWall(2026, 10, 2)), now);
    expect(w.total).toBe(1);
    expect(w.workedMs).toBe(3 * HOUR);
    expect(w.delayed).toBe(1);
    expect(w.interruptions).toBe(1);
    expect(w.planDiffMs).toBe(-1 * HOUR);
    const d2 = periodStats([t], periodRange('day', fromWall(2026, 10, 2)), now);
    const d3 = periodStats([t], periodRange('day', fromWall(2026, 10, 3)), now);
    expect(d2.total + d3.total).toBe(1);
    expect(d2.workedMs + d3.workedMs).toBe(3 * HOUR);
    expect(w.byHour[23]).toBe(HOUR);
    expect(w.byWeekday.reduce((a, b) => a + b, 0)).toBe(3 * HOUR);
    expect(w.buckets.reduce((s, b) => s + b.workedMs, 0)).toBe(3 * HOUR);
  });
});

import { makeEvent, MINUTE, planNotices } from './index';
describe('複数の通知（v2）', () => {
  it('タスクと予定の extra.notifies をそれぞれ1回ずつ送る', () => {
    const start = fromWall(2026, 10, 5, 10);
    const t = makeTask({ title: 'T', kind: 'do', plannedStart: start, plannedEnd: start + HOUR, extra: { notifies: [10, 60] } }, start - 2 * HOUR);
    const e = makeEvent({ title: 'E', calendarId: 'c', start, end: start + HOUR, extra: { notifies: [0, 1440] } }, start - 2 * HOUR);
    expect(planNotices([t], [e], [], start - 60 * MINUTE, 5 * MINUTE).map((n) => n.body)).toEqual(['1時間後に開始します']);
    expect(planNotices([t], [e], [], start - 10 * MINUTE, 5 * MINUTE).map((n) => n.key)).toEqual([`remind:${t.id}:${start}:10`]);
    expect(planNotices([t], [e], [], start, 5 * MINUTE).map((n) => n.title)).toEqual(['E']);
    expect(planNotices([t], [e], [], start - 1440 * MINUTE, 5 * MINUTE)[0]?.body).toContain('1日後');
  });
});

describe('分析の追加指標（v3 C31）', () => {
  it('予定時間・中断・カテゴリー別・ヒートマップの合計が実行時間と一致し、二重計上しない', () => {
    const now = fromWall(2026, 10, 10);
    const a = makeTask({ title: 'A', kind: 'do', category: 'ゼミ', plannedStart: fromWall(2026, 10, 2, 9), plannedEnd: fromWall(2026, 10, 2, 11), status: 'done', actualEnd: fromWall(2026, 10, 2, 11), intervals: [{ start: fromWall(2026, 10, 2, 9), end: fromWall(2026, 10, 2, 10) }, { start: fromWall(2026, 10, 2, 10, 30), end: fromWall(2026, 10, 2, 11) }] }, now);
    const b = makeTask({ title: 'B', kind: 'do', plannedStart: fromWall(2026, 10, 3, 14), plannedEnd: fromWall(2026, 10, 3, 15), intervals: [{ start: fromWall(2026, 10, 3, 14), end: fromWall(2026, 10, 3, 15) }] }, now);
    const st = periodStats([a, b], periodRange('week', fromWall(2026, 10, 2)), now);
    expect(st.buckets.reduce((s, x) => s + x.plannedMs, 0)).toBe(3 * HOUR);
    expect(st.buckets.reduce((s, x) => s + x.interruptions, 0)).toBe(1);
    expect(st.heat.flat().reduce((s, x) => s + x, 0)).toBe(st.workedMs);
    expect(st.byCategory.reduce((s, x) => s + x.workedMs, 0)).toBe(st.workedMs);
    expect(st.byCategory.find((c) => c.category === 'ゼミ')).toMatchObject({ done: 1, total: 1 });
  });
});
