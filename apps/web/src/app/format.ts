import { formatDayLabel, formatHm, isSameDay } from '@my-time/domain';

const pad = (n: number) => String(n).padStart(2, '0');

/** epoch → `<input type="datetime-local">` の値（端末ローカル） */
export function toLocalInput(t: number): string {
  const d = new Date(t);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function fromLocalInput(v: string): number | null {
  if (!v) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(v);
  if (!m) return null;
  return new Date(+m[1]!, +m[2]! - 1, +m[3]!, +m[4]!, +m[5]!).getTime();
}

export function formatRange(start: number, end: number): string {
  if (isSameDay(start, end)) return `${formatDayLabel(start)} ${formatHm(start)}〜${formatHm(end)}`;
  return `${formatDayLabel(start)} ${formatHm(start)}〜${formatDayLabel(end)} ${formatHm(end)}`;
}

export function formatMonth(t: number): string {
  const d = new Date(t);
  return `${d.getFullYear()}年${d.getMonth() + 1}月`;
}

export function formatFull(t: number): string {
  const d = new Date(t);
  return `${d.getMonth() + 1}月${formatDayLabel(t)} ${formatHm(t)}`;
}
