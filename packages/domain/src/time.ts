import type { EpochMs } from './types';

export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;

/**
 * 暦計算のタイムゾーン。ブラウザでは端末のローカル時刻（null）、サーバー（UTCで動く）では
 * setDomainTimeZone('Asia/Tokyo') を呼んで利用者の時刻で日付・曜日・時刻を判定する。
 */
let fmt: Intl.DateTimeFormat | null = null;

export function setDomainTimeZone(tz: string | null): void {
  fmt = tz
    ? new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric', weekday: 'short' })
    : null;
}

export interface Wall {
  y: number;
  /** 0始まり */
  mo: number;
  d: number;
  h: number;
  mi: number;
  s: number;
  ms: number;
  /** 0=日 */
  wd: number;
}

const WD: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

/** 指定時刻の「壁時計」（設定タイムゾーンでの年月日・時刻・曜日） */
export function wall(t: EpochMs): Wall {
  if (!fmt) {
    const d = new Date(t);
    return { y: d.getFullYear(), mo: d.getMonth(), d: d.getDate(), h: d.getHours(), mi: d.getMinutes(), s: d.getSeconds(), ms: d.getMilliseconds(), wd: d.getDay() };
  }
  const p: Record<string, string> = {};
  for (const x of fmt.formatToParts(new Date(t))) p[x.type] = x.value;
  return { y: +p.year!, mo: +p.month! - 1, d: +p.day!, h: +p.hour!, mi: +p.minute!, s: +p.second!, ms: ((t % 1000) + 1000) % 1000, wd: WD[p.weekday!] ?? 0 };
}

/** 壁時計 → 時刻（範囲外の日・月は Date と同じく繰り上がる） */
export function fromWall(y: number, mo: number, d: number, h = 0, mi = 0, s = 0, ms = 0): EpochMs {
  if (!fmt) return new Date(y, mo, d, h, mi, s, ms).getTime();
  const naive = Date.UTC(y, mo, d, h, mi, s, ms);
  let guess = naive;
  for (let i = 0; i < 3; i++) {
    const w = wall(guess);
    const asUtc = Date.UTC(w.y, w.mo, w.d, w.h, w.mi, w.s, w.ms);
    const diff = naive - asUtc;
    if (diff === 0) break;
    guess += diff;
  }
  return guess;
}

/** 日付の 0:00（設定タイムゾーン）。夏時間のある地域でも暦計算で正しく求める。 */
export function startOfDay(t: EpochMs): EpochMs {
  const w = wall(t);
  return fromWall(w.y, w.mo, w.d);
}

export function addDays(t: EpochMs, n: number): EpochMs {
  const w = wall(t);
  return fromWall(w.y, w.mo, w.d + n, w.h, w.mi, w.s, w.ms);
}

/** n か月後（月末は短い月の末日に丸める） */
export function addMonths(t: EpochMs, n: number): EpochMs {
  const w = wall(t);
  const last = new Date(Date.UTC(w.y, w.mo + n + 1, 0)).getUTCDate();
  return fromWall(w.y, w.mo + n, Math.min(w.d, last), w.h, w.mi, w.s, w.ms);
}

export function weekday(t: EpochMs): number {
  return wall(t).wd;
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
  return WEEK_JA[wall(t).wd] ?? '';
}

/** 例: 12日(日) */
export function formatDayLabel(t: EpochMs): string {
  return `${wall(t).d}日(${weekdayJa(t)})`;
}

export function formatHm(t: EpochMs): string {
  const w = wall(t);
  return `${w.h}:${String(w.mi).padStart(2, '0')}`;
}

export function formatDuration(ms: number): string {
  const totalMin = Math.max(0, Math.round(ms / MINUTE));
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  if (h === 0) return `${m}分`;
  return m === 0 ? `${h}時間` : `${h}時間${m}分`;
}
