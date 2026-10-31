import type { EpochMs } from './types';
import { addDays, startOfDay } from './time';

export interface MonthItem {
  id: string;
  start: EpochMs;
  end: EpochMs;
}

export interface WeekBar<T extends MonthItem> {
  item: T;
  /** 週内の開始列（0=日曜） */
  col: number;
  /** 何日分にまたがるか（1以上） */
  span: number;
  /** 段（上から0） */
  lane: number;
  /** 前の週から続いている／次の週へ続く */
  continuesBefore: boolean;
  continuesAfter: boolean;
}

/** 最後に表示される日（0:00ちょうどに終わる予定は前日まで） */
function lastDay(item: MonthItem): EpochMs {
  const endDay = startOfDay(item.end);
  return item.end === endDay && item.end > item.start ? addDays(endDay, -1) : endDay;
}

/** 2日以上にまたがる予定か */
export function isMultiDay(item: MonthItem): boolean {
  return lastDay(item) > startOfDay(item.start);
}

/**
 * 月表示の1週（7日）に、日付またぎの予定を「連続したバー」として段に詰めて配置する。
 * 長いもの・早いものを優先して上の段に置く。
 */
export function layoutWeekBars<T extends MonthItem>(items: readonly T[], weekStart: EpochMs): WeekBar<T>[] {
  const weekEnd = addDays(weekStart, 7);
  const dayIndex = (t: EpochMs) => Math.round((startOfDay(t) - weekStart) / 86_400_000);
  const bars = items
    .filter((it) => isMultiDay(it) && it.start < weekEnd && lastDay(it) >= weekStart)
    .map((it) => {
      const first = Math.max(0, dayIndex(it.start));
      const last = Math.min(6, dayIndex(lastDay(it)));
      return { item: it, col: first, span: last - first + 1, continuesBefore: startOfDay(it.start) < weekStart, continuesAfter: lastDay(it) >= weekEnd };
    })
    .sort((a, b) => a.col - b.col || b.span - a.span || a.item.start - b.item.start);

  const laneEnds: number[] = [];
  return bars.map((b) => {
    let lane = laneEnds.findIndex((endCol) => endCol < b.col);
    if (lane === -1) {
      lane = laneEnds.length;
      laneEnds.push(b.col + b.span - 1);
    } else laneEnds[lane] = b.col + b.span - 1;
    return { ...b, lane };
  });
}
