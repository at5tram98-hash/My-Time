import type { CalEvent, EpochMs, Task } from './types';
import { DAY, startOfDay } from './time';
import { ruleStarts, seriesEnded } from './recurrence';

export const RETENTION_DAYS = 30;
const KEEP = RETENTION_DAYS * DAY;

export type Retention =
  | { state: 'keep'; reason: string }
  /** 期限到来。dueAt 以降、検証済みバックアップに含まれていれば物理削除してよい */
  | { state: 'due'; dueAt: EpochMs; reason: string };

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

/**
 * タスクの期限判定（仕様 v1.2 の30日ルール。起点は次の順で1つだけ選ぶ）
 * 1. 試験日時が設定されたテスト対策 … 試験日時から30日
 * 2. 確認タスクで確認日時あり       … 確認日時から30日
 * 3. 作業日時（予定の開始・終了）あり … 終了日時から30日（実績の終了がそれより後ならそちら）
 * 4. 上記の日時がない（提出期限だけの課題も含む） … 作成日から30日
 * いずれも「起点より後の実績終了」があれば遅い方を採る（早く消すことはしない）。
 */
export function taskRetention(t: Task): Retention {
  const later = (base: EpochMs) => Math.max(base, t.actualEnd ?? 0);
  if (t.special === 'testPrep' && t.testPrep?.examAt != null) return { state: 'due', dueAt: later(t.testPrep.examAt) + KEEP, reason: '試験日から30日' };
  if (t.kind === 'check' && t.checkAt != null) return { state: 'due', dueAt: t.checkAt + KEEP, reason: '確認日時から30日' };
  if (t.plannedStart != null) return { state: 'due', dueAt: later(t.plannedEnd ?? t.plannedStart) + KEEP, reason: '終了日から30日' };
  return { state: 'due', dueAt: later(t.createdAt) + KEEP, reason: t.special === 'assignment' ? '作成日から30日（提出期限のみの課題）' : '作成日から30日（日時なし）' };
}

export function isDue(r: Retention, now: EpochMs): boolean {
  return r.state === 'due' && r.dueAt <= now;
}
