import type { EpochMs } from './types';
import { addDays, clipToDay, MINUTE } from './time';

export interface TimedItem {
  id: string;
  start: EpochMs;
  end: EpochMs;
}

export interface PlacedItem<T extends TimedItem> {
  item: T;
  /** 日の 0:00 からの分 */
  top: number;
  height: number;
  column: number;
  columns: number;
  clippedStart: boolean;
  clippedEnd: boolean;
}

/**
 * 1日の列に予定を並べる。重なるもの同士は横に分割（Appleカレンダーと同様のクラスター方式）。
 */
export function layoutDay<T extends TimedItem>(items: readonly T[], dayStart: EpochMs, minMinutes = 15): PlacedItem<T>[] {
  const dayEnd = addDays(dayStart, 1);
  const visible = items
    .filter((it) => it.start < dayEnd && Math.max(it.end, it.start + MINUTE) > dayStart)
    .map((it) => {
      const c = clipToDay(it.start, Math.max(it.end, it.start + minMinutes * MINUTE), dayStart);
      return { it, ...c };
    })
    .sort((a, b) => a.start - b.start || b.end - a.end);

  const result: PlacedItem<T>[] = [];
  let cluster: typeof visible = [];
  let clusterEnd = -Infinity;

  const flush = () => {
    const colEnds: number[] = [];
    const assigned = cluster.map((c) => {
      let col = colEnds.findIndex((e) => e <= c.start);
      if (col === -1) {
        col = colEnds.length;
        colEnds.push(c.end);
      } else colEnds[col] = c.end;
      return { c, col };
    });
    for (const { c, col } of assigned) {
      result.push({
        item: c.it,
        top: (c.start - dayStart) / MINUTE,
        height: Math.max(minMinutes, (c.end - c.start) / MINUTE),
        column: col,
        columns: colEnds.length,
        clippedStart: c.clippedStart,
        clippedEnd: c.clippedEnd,
      });
    }
    cluster = [];
    clusterEnd = -Infinity;
  };

  for (const v of visible) {
    if (v.start >= clusterEnd && cluster.length) flush();
    cluster.push(v);
    clusterEnd = Math.max(clusterEnd, v.end);
  }
  if (cluster.length) flush();
  return result;
}

/** 区間の重なり検出 */
export function overlaps(a: { start: EpochMs; end: EpochMs }, b: { start: EpochMs; end: EpochMs }): boolean {
  return a.start < b.end && b.start < a.end;
}

export function findConflicts<T extends TimedItem>(target: TimedItem, others: readonly T[]): T[] {
  return others.filter((o) => o.id !== target.id && overlaps(target, o));
}

/**
 * 重なった場合の代替時刻を「提案」する（自動では移動しない）。
 * 同じ長さで、指定日の dayFrom〜dayTo 時の間にある最初の空き枠を15分刻みで探す。
 */
export function suggestFreeSlot(target: TimedItem, others: readonly TimedItem[], dayStart: EpochMs, dayFromHour = 7, dayToHour = 23, stepMin = 15): { start: EpochMs; end: EpochMs } | null {
  const dur = target.end - target.start;
  const from = Math.max(target.start, dayStart + dayFromHour * 60 * MINUTE);
  const limit = dayStart + dayToHour * 60 * MINUTE;
  const step = stepMin * MINUTE;
  const aligned = dayStart + Math.ceil((from - dayStart) / step) * step;
  for (let s = aligned; s + dur <= limit; s += step) {
    const cand = { start: s, end: s + dur };
    if (!others.some((o) => o.id !== target.id && overlaps(cand, o))) return cand;
  }
  return null;
}
