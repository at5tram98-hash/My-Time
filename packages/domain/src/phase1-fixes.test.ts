import { describe, expect, it } from 'vitest';
import { addDays, applyTaskAction, checkPlacement, HOUR, isMultiDay, layoutWeekBars, makeEvent, makeTask, MINUTE, placementItems, startOfDay } from './index';

const day = startOfDay(new Date(2026, 9, 12, 12).getTime()); // 月曜
const at = (h: number, m = 0, d = 0) => addDays(day, d) + h * HOUR + m * MINUTE;

describe('保存前の重複チェック', () => {
  const ev = makeEvent({ title: '授業', calendarId: 'c', start: at(10), end: at(12) }, 0);
  const done = applyTaskAction(applyTaskAction(makeTask({ title: '完了済み', plannedStart: at(13), plannedEnd: at(14) }, 0), 'start', at(13)).task, 'finish', at(14)).task;
  const t = makeTask({ title: '課題', plannedStart: at(15), plannedEnd: at(16) }, 0);
  const others = placementItems([ev], [t, done]);

  it('予定と未完了の時刻指定タスクが対象（完了済みは対象外）', () => {
    expect(others.map((o) => o.title)).toEqual(['授業', '課題']);
  });
  it('重ならなければ提案なし', () => {
    expect(checkPlacement({ id: 'n', start: at(13), end: at(14) }, others)).toEqual({ conflicts: [], suggestion: null });
  });
  it('重なれば相手と空き時間の候補を返し、既存予定は変えない', () => {
    const r = checkPlacement({ id: 'n', start: at(11), end: at(12) }, others);
    expect(r.conflicts.map((c) => c.title)).toEqual(['授業']);
    expect(r.suggestion).toEqual({ start: at(12), end: at(13) });
    expect(ev.start).toBe(at(10));
  });
  it('自分自身は重複に数えない（編集・移動時）', () => {
    expect(checkPlacement({ id: `event:${ev.id}`, start: at(10, 30), end: at(11, 30) }, others).conflicts).toEqual([]);
  });
  it('その日に空きがなければ翌日の候補を返す', () => {
    const full = placementItems([makeEvent({ title: '終日', calendarId: 'c', start: at(7), end: at(23) }, 0)], []);
    const r = checkPlacement({ id: 'n', start: at(9), end: at(10) }, full);
    expect(r.suggestion?.start).toBe(at(8, 0, 1));
  });
});

describe('月表示の日付またぎバー', () => {
  const wk = addDays(day, -1); // 日曜始まり
  it('0:00ちょうどに終わる予定は1日扱い', () => {
    expect(isMultiDay({ id: 'a', start: at(10), end: at(0, 0, 1) })).toBe(false);
    expect(isMultiDay({ id: 'b', start: at(22), end: at(6, 0, 1) })).toBe(true);
  });
  it('連続したバーとして列・幅・段を求める', () => {
    const bars = layoutWeekBars(
      [
        { id: 'night', start: at(22), end: at(6, 0, 1) }, // 月→火
        { id: 'trip', start: at(9, 0, 1), end: at(18, 0, 3) }, // 火→木
        { id: 'camp', start: at(9), end: at(18, 0, 2) }, // 月→水
      ],
      wk,
    );
    const by = Object.fromEntries(bars.map((b) => [b.item.id, b]));
    expect(by.camp).toMatchObject({ col: 1, span: 3, lane: 0 });
    expect(by.night).toMatchObject({ col: 1, span: 2, lane: 1 });
    expect(by.trip).toMatchObject({ col: 2, span: 3, lane: 2 });
  });
  it('週をまたぐ予定は両方の週で続きの印を持つ', () => {
    const long = { id: 'l', start: at(9, 0, 4), end: at(9, 0, 8) }; // 金→翌火
    const w1 = layoutWeekBars([long], wk)[0]!;
    const w2 = layoutWeekBars([long], addDays(wk, 7))[0]!;
    expect(w1).toMatchObject({ col: 5, span: 2, continuesAfter: true, continuesBefore: false });
    expect(w2).toMatchObject({ col: 0, span: 3, continuesBefore: true, continuesAfter: false });
  });
});
