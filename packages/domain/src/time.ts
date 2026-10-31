import type { EpochMs } from './types';

export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;

/** 端末ローカルの日付の 0:00。夏時間のある地域でも Date の暦計算で正しく求める。 */
export function startOfDay(t: EpochMs): EpochMs {
  const d = new Date(t);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

export function addDays(t: EpochMs, n: number): EpochMs {
  const d = new Date(t);
  d.setDate(d.getDate() + n);
  return d.getTime();
}

export function isSameDay(a: EpochMs, b: EpochMs): boolean {
  return startOfDay(a) === startOfDay(b);
}

/** 15分などの刻みに丸める（ローカル日の 0:00 基準）。 */
export function snapToStep(t: EpochMs, stepMinutes = 15): EpochMs {
  const day = startOfDay(t);
  const step = stepMinutes * MINUTE;
  return day + Math.round((t - day) / step) * step;
}

/** 開始・終了の区間が [dayStart, dayStart+1日) と重なるか */
export function overlapsDay(start: EpochMs, end: EpochMs, dayStart: EpochMs): boolean {
  const dayEnd = addDays(dayStart, 1);
  if (end <= start) return start >= dayStart && start < dayEnd;
  return start < dayEnd && end > dayStart;
}

/** 日をまたぐ区間を、指定日に表示する部分へ切り詰める */
export function clipToDay(start: EpochMs, end: EpochMs, dayStart: EpochMs): { start: EpochMs; end: EpochMs; clippedStart: boolean; clippedEnd: boolean } {
  const dayEnd = addDays(dayStart, 1);
  return {
    start: Math.max(start, dayStart),
    end: Math.min(end, dayEnd),
    clippedStart: start < dayStart,
    clippedEnd: end > dayEnd,
  };
}

const WEEK_JA = ['日', '月', '火', '水', '木', '金', '土'] as const;

export function weekdayJa(t: EpochMs): string {
  return WEEK_JA[new Date(t).getDay()] ?? '';
}

/** 例: 12日(日) */
export function formatDayLabel(t: EpochMs): string {
  const d = new Date(t);
  return `${d.getDate()}日(${weekdayJa(t)})`;
}

export function formatHm(t: EpochMs): string {
  const d = new Date(t);
  return `${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`;
}

export function formatDuration(ms: number): string {
  const totalMin = Math.max(0, Math.round(ms / MINUTE));
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  if (h === 0) return `${m}分`;
  return m === 0 ? `${h}時間` : `${h}時間${m}分`;
}
