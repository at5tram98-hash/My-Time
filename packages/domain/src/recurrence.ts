import type { CalEvent, EpochMs, RecurrenceException } from './types';
import { addDays, addMonths, DAY, fromWall, wall, weekday } from './time';

/** 繰り返しの1回。id は `${マスターID}@${規則上の開始時刻}` で安定。 */
export interface Occurrence extends CalEvent {
  masterId: string;
  originalStart: EpochMs;
  isOccurrence: true;
}

const MAX_ITER = 3660;

/** 規則どおりの開始時刻を [from, to) の範囲で列挙（暦計算なので夏時間・月末でも時刻がずれない） */
export function ruleStarts(ev: CalEvent, from: EpochMs, to: EpochMs): EpochMs[] {
  const r = ev.recurrence;
  if (!r) return ev.start < to && ev.end > from ? [ev.start] : [];
  const dur = ev.end - ev.start;
  const out: EpochMs[] = [];
  const interval = Math.max(1, r.interval);
  const push = (s: EpochMs) => {
    if (r.until != null && s > r.until) return false;
    if (s + dur > from && s < to) out.push(s);
    return s < to;
  };
  if (r.freq === 'weekly') {
    const baseWd = weekday(ev.start);
    const days = (r.byWeekday && r.byWeekday.length ? [...r.byWeekday] : [baseWd]).sort((a, b) => a - b);
    // 初回を含む週の日曜
    const weekStart = addDays(ev.start, -baseWd);
    for (let w = 0; w < MAX_ITER; w += interval) {
      let cont = true;
      for (const wd of days) {
        const s = addDays(weekStart, w * 7 + wd);
        if (s < ev.start) continue;
        if (!push(s)) {
          cont = false;
          break;
        }
      }
      if (!cont || (r.until != null && addDays(weekStart, w * 7) > r.until)) break;
    }
    return out;
  }
  for (let i = 0; i < MAX_ITER; i++) {
    const s = r.freq === 'daily' ? addDays(ev.start, i * interval) : addMonths(ev.start, i * interval);
    if (!push(s)) break;
  }
  return out;
}

/** 表示範囲内の回を展開。例外（その回のみ変更・削除・期限処理済み）を反映する。 */
export function expandEvent(ev: CalEvent, from: EpochMs, to: EpochMs): (CalEvent | Occurrence)[] {
  if (!ev.recurrence) return ev.start < to && ev.end > from ? [ev] : [];
  const byStart = new Map<EpochMs, RecurrenceException>(ev.exceptions.map((x) => [x.originalStart, x]));
  const dur = ev.end - ev.start;
  // 時間を後ろへ動かした例外が範囲に入る場合も拾えるよう、少し広めに列挙
  const starts = ruleStarts(ev, from - 7 * DAY, to + 7 * DAY);
  const out: Occurrence[] = [];
  for (const s of starts) {
    const x = byStart.get(s);
    if (x && (x.kind === 'cancelled' || x.kind === 'archived')) continue;
    const start = x?.start ?? s;
    const end = x?.end ?? s + dur;
    if (!(start < to && end > from)) continue;
    out.push({
      ...ev,
      id: `${ev.id}@${s}`,
      masterId: ev.id,
      originalStart: s,
      isOccurrence: true,
      start,
      end,
      title: x?.title ?? ev.title,
      notes: x?.notes ?? ev.notes,
    });
  }
  return out;
}

export function expandAll(events: readonly CalEvent[], from: EpochMs, to: EpochMs): (CalEvent | Occurrence)[] {
  return events.flatMap((e) => expandEvent(e, from, to)).sort((a, b) => a.start - b.start);
}

export function isOccurrence(e: CalEvent | Occurrence): e is Occurrence {
  return (e as Occurrence).isOccurrence === true;
}

export function parseOccurrenceId(id: string): { masterId: string; originalStart: EpochMs } | null {
  const i = id.lastIndexOf('@');
  if (i < 0) return null;
  const n = Number(id.slice(i + 1));
  return Number.isFinite(n) ? { masterId: id.slice(0, i), originalStart: n } : null;
}

function upsertException(ev: CalEvent, x: RecurrenceException, now: EpochMs): CalEvent {
  return { ...ev, exceptions: [...ev.exceptions.filter((e) => e.originalStart !== x.originalStart), x], updatedAt: now };
}

/** 「この回のみ」変更 */
export function editThisOccurrence(master: CalEvent, originalStart: EpochMs, patch: { start?: EpochMs; end?: EpochMs; title?: string; notes?: string }, now: EpochMs): CalEvent {
  const prev = master.exceptions.find((x) => x.originalStart === originalStart && x.kind === 'override');
  return upsertException(master, { ...prev, ...patch, originalStart, kind: 'override' }, now);
}

/** 「この回のみ」削除 */
export function cancelThisOccurrence(master: CalEvent, originalStart: EpochMs, now: EpochMs): CalEvent {
  return upsertException(master, { originalStart, kind: 'cancelled' }, now);
}

/**
 * 「この回以降すべて」変更：元のマスターはこの回の直前で打ち切り、この回からの新しいマスターを作る。
 * 過去の回（元のマスター）は保護され、変更されない。
 */
export function splitFromOccurrence(master: CalEvent, originalStart: EpochMs, patch: Partial<Omit<CalEvent, 'id' | 'createdAt' | 'updatedAt' | 'exceptions'>>, newId: string, now: EpochMs): { before: CalEvent | null; after: CalEvent } {
  if (!master.recurrence) throw new Error('繰り返し予定ではありません');
  const dur = master.end - master.start;
  const start = patch.start ?? originalStart;
  const end = patch.end ?? start + dur;
  const after: CalEvent = {
    ...master,
    ...patch,
    recurrence: patch.recurrence === undefined ? master.recurrence : patch.recurrence,
    id: newId,
    start,
    end,
    exceptions: master.exceptions.filter((x) => x.originalStart >= originalStart).map((x) => ({ ...x, originalStart: x.originalStart - originalStart + start })),
    createdAt: now,
    updatedAt: now,
  };
  if (originalStart <= master.start) return { before: null, after };
  const before: CalEvent = {
    ...master,
    recurrence: { ...master.recurrence, until: originalStart - 1 },
    exceptions: master.exceptions.filter((x) => x.originalStart < originalStart),
    updatedAt: now,
  };
  return { before, after };
}

/** 規則上、指定時刻以降にもう回が発生しないか（期限削除でマスターを残すかの判定に使う） */
export function seriesEnded(ev: CalEvent, now: EpochMs): boolean {
  if (!ev.recurrence) return ev.end <= now;
  if (ev.recurrence.until == null) return false;
  return ruleStarts(ev, now, ev.recurrence.until + DAY).length === 0;
}

/** 複数日へのコピー：同じ時刻・長さで指定日に複製（既存予定は変更しない） */
export function copyToDays(ev: CalEvent, dayStarts: readonly EpochMs[], makeId: () => string, now: EpochMs): CalEvent[] {
  const w = wall(ev.start);
  const dur = ev.end - ev.start;
  const at = (d: EpochMs) => {
    const dw = wall(d);
    return fromWall(dw.y, dw.mo, dw.d, w.h, w.mi);
  };
  return dayStarts.map((d) => ({ ...ev, id: makeId(), start: at(d), end: at(d) + dur, recurrence: null, exceptions: [], source: null, createdAt: now, updatedAt: now }));
}
