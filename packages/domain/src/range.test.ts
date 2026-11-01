import { describe, expect, it } from 'vitest';
import { HOUR, makeTask, startOfDay, taskBlock, tasksForRange, DAY } from './index';

describe('時間軸の範囲に現れうるタスクの絞り込み', () => {
  const d0 = startOfDay(new Date(2026, 9, 12).getTime());
  const now = d0 + 10 * HOUR;
  const mk = (id: string, dayOff: number, status: 'notStarted' | 'done' = 'notStarted') =>
    makeTask({ id, title: id, status, plannedStart: d0 + dayOff * DAY + 9 * HOUR, plannedEnd: d0 + dayOff * DAY + 10 * HOUR }, d0);
  it('範囲外の完了タスクは除き、遅延して今日まで伸びる古いタスクは含める', () => {
    const tasks = [mk('today', 0), mk('old-done', -30, 'done'), mk('old-open', -30), mk('future', 5), mk('tomorrow', 1)];
    const ids = tasksForRange(tasks, d0, d0 + 2 * DAY, now).map((t) => t.id);
    expect(ids).toEqual(['today', 'old-open', 'tomorrow']);
  });
  it('taskBlock が範囲に重なるタスクを1件も落とさない（上位集合）', () => {
    const tasks = Array.from({ length: 200 }, (_, i) => mk(`t${i}`, (i % 40) - 20, i % 3 === 0 ? 'done' : 'notStarted'));
    for (let off = -5; off <= 5; off++) {
      const from = d0 + off * DAY;
      const to = from + 2 * DAY;
      const expected = tasks.filter((t) => { const b = taskBlock(t, [], now); return b && b.start < to && b.end > from; }).map((t) => t.id);
      const got = new Set(tasksForRange(tasks, from, to, now).map((t) => t.id));
      for (const id of expected) expect(got.has(id)).toBe(true);
    }
  });
});
