import type { CalEvent, EpochMs, Task } from './types';
import { DAY, startOfDay } from './time';
import { ruleStarts, seriesEnded } from './recurrence';

export const RETENTION_DAYS = 30;
const KEEP = RETENTION_DAYS * DAY;

export type Retention =
  | { state: 'keep'; reason: string }
  /** 期限到来。dueAt 以降、検証済みバックアップに含まれていれば物理削除してよい */
  | { state: 'due'; dueAt: EpochMs; reason: string }
  /** 起点が未確定などの理由で削除しない（docs/open-questions.md） */
  | { state: 'hold'; reason: string };

/** 日付をまたぐ予定か */
export function crossesDate(ev: Pick<CalEvent, 'start' | 'end'>): boolean {
  return startOfDay(ev.start) !== startOfDay(ev.end - 1);
}

/** 特則：フラグ付きの日付またぎ予定は、終了した直後から通常画面に出さない */
export function hiddenAfterEnd(ev: CalEvent, now: EpochMs): boolean {
  return ev.hideAfterEnd && !ev.recurrence && crossesDate(ev) && ev.end <= now;
}

/** 予定の期限判定（繰り返しのマスターは継続中なら残す） */
export function eventRetention(ev: CalEvent, now: EpochMs): Retention {
  if (ev.recurrence) {
    if (!seriesEnded(ev, now - KEEP)) return { state: 'keep', reason: '繰り返しが継続中のマスター' };
    const until = ev.recurrence.until ?? ev.end;
    const last = ruleStarts(ev, ev.start, until + 1).pop() ?? ev.start;
    return { state: 'due', dueAt: last + (ev.end - ev.start) + KEEP, reason: '繰り返しの最終回から30日' };
  }
  if (ev.hideAfterEnd && crossesDate(ev)) return { state: 'due', dueAt: ev.end, reason: '日付またぎの特則（終了直後）' };
  return { state: 'due', dueAt: ev.end + KEEP, reason: '終了日から30日' };
}

/** 繰り返しの過去の各回のうち、期限が来たもの（例外 archived を付けて個別に処理する） */
export function dueOccurrences(ev: CalEvent, now: EpochMs): EpochMs[] {
  if (!ev.recurrence) return [];
  const dur = ev.end - ev.start;
  const handled = new Set(ev.exceptions.filter((x) => x.kind === 'archived' || x.kind === 'cancelled').map((x) => x.originalStart));
  return ruleStarts(ev, ev.start, now - KEEP).filter((s) => {
    const x = ev.exceptions.find((e) => e.originalStart === s);
    const end = x?.end ?? s + dur;
    return !handled.has(s) && end + KEEP <= now;
  });
}

/** タスクの期限判定 */
export function taskRetention(t: Task): Retention {
  if (t.special === 'testPrep' && t.testPrep?.examAt != null) return { state: 'due', dueAt: t.testPrep.examAt + KEEP, reason: '試験日から30日' };
  if (t.kind === 'check') {
    if (t.checkAt != null) return { state: 'due', dueAt: t.checkAt + KEEP, reason: '確認日時から30日' };
    return { state: 'due', dueAt: t.createdAt + KEEP, reason: '作成日から30日（日時なし）' };
  }
  if (t.plannedStart != null) {
    const end = Math.max(t.plannedEnd ?? t.plannedStart, t.actualEnd ?? 0);
    return { state: 'due', dueAt: end + KEEP, reason: '終了日から30日' };
  }
  if (t.special === 'assignment' && t.assignment?.deadline != null) {
    return { state: 'hold', reason: '提出期限のみの課題は起点が未確定のため削除しない' };
  }
  return { state: 'due', dueAt: t.createdAt + KEEP, reason: '作成日から30日（日時なし）' };
}

export function isDue(r: Retention, now: EpochMs): boolean {
  return r.state === 'due' && r.dueAt <= now;
}
