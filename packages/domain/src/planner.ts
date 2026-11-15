/**
 * 計画の支援（アプリ内の規則だけで動く。外部のAIには送らない）。
 * - 空き時間の算出、問題の検知（重なり・二重登録・移動不足・期限の不足・詰め込み・遅刻）、次の行動、再計画の提案、振り返りの集計。
 * - 提案は「変更前→変更後」の差分（Change）として返すだけ。保存はユーザーが承認したときに repo.applyPlan が行う。
 * - 時間が決まった予定（授業・勤務・取り込んだ予定）は動かさない。動かす候補はタスクと作業枠（日時付きサブタスク）だけ。
 */
import type { CalEvent, EpochMs, Subtask, Task } from './types';
import type { Occurrence } from './recurrence';
import { addDays, formatHm, HOUR, MINUTE, startOfDay } from './time';
import { overlaps } from './layout';
import { workedMs, delayInfo, estimateEnd } from './progress';
import { deadlineOf, num, shiftPay, specOf, SPEC_BY_ID, workplaceOf, type SpecGroup, type SpecTypeId } from './spec';
import type { Employer } from './types';

export interface Interval { start: EpochMs; end: EpochMs }

export interface BusyItem extends Interval {
  id: string;
  title: string;
  kind: 'event' | 'task' | 'session' | 'buffer';
  /** 固定（予定）か、動かせる（タスク・作業枠）か */
  fixed: boolean;
  refId: string;
}

export interface PlanOptions { fromHour: number; toHour: number; stepMin: number }
export const DEFAULT_PLAN: PlanOptions = { fromHour: 7, toHour: 23, stepMin: 15 };

type Ev = CalEvent | Occurrence;
const evId = (e: Ev) => e.id;

/** 時間を使うものの一覧（予定・時刻のあるタスク・作業枠・移動のバッファ）。完了したタスクは含めない */
export function busyItems(events: readonly Ev[], tasks: readonly Task[], subtasks: readonly Subtask[] = []): BusyItem[] {
  const out: BusyItem[] = [];
  for (const e of events) {
    if (e.extra?.allDay) continue;
    out.push({ id: `event:${evId(e)}`, refId: evId(e), title: e.title, kind: 'event', fixed: true, start: e.start, end: e.end });
    const travel = e.extra?.travelMinutes;
    if (travel) out.push({ id: `buffer:${evId(e)}`, refId: evId(e), title: `${e.title}への移動`, kind: 'buffer', fixed: true, start: e.start - travel * MINUTE, end: e.start });
  }
  const open = new Set(tasks.filter((t) => t.status !== 'done').map((t) => t.id));
  for (const t of tasks) {
    if (t.kind !== 'do' || t.status === 'done' || t.plannedStart == null || t.plannedEnd == null) continue;
    out.push({ id: `task:${t.id}`, refId: t.id, title: t.title, kind: 'task', fixed: false, start: t.plannedStart, end: t.plannedEnd });
  }
  for (const s of subtasks) {
    if (s.done || s.plannedStart == null || s.plannedEnd == null || !open.has(s.taskId)) continue;
    out.push({ id: `session:${s.id}`, refId: s.id, title: s.title, kind: 'session', fixed: false, start: s.plannedStart, end: s.plannedEnd });
  }
  return out.sort((a, b) => a.start - b.start);
}

/** 区間の和（重なりを二重に数えない） */
export function unionMinutes(items: readonly Interval[], from: EpochMs, to: EpochMs): number {
  const xs = items.map((i) => ({ start: Math.max(from, i.start), end: Math.min(to, i.end) })).filter((i) => i.end > i.start).sort((a, b) => a.start - b.start);
  let total = 0;
  let cur: Interval | null = null;
  for (const x of xs) {
    if (!cur || x.start > cur.end) { if (cur) total += cur.end - cur.start; cur = { ...x }; }
    else cur.end = Math.max(cur.end, x.end);
  }
  if (cur) total += cur.end - cur.start;
  return Math.round(total / MINUTE);
}

/** 1日の活動時間帯（fromHour〜toHour）の空き。after より前は使わない */
export function freeSlots(day: EpochMs, busy: readonly Interval[], opts: PlanOptions = DEFAULT_PLAN, after: EpochMs = 0, minMinutes = 15): Interval[] {
  const d0 = startOfDay(day);
  const step = opts.stepMin * MINUTE;
  let from = Math.max(d0 + opts.fromHour * HOUR, after);
  from = d0 + Math.ceil((from - d0) / step) * step;
  const to = d0 + opts.toHour * HOUR;
  if (from >= to) return [];
  const xs = busy.filter((b) => b.end > from && b.start < to).sort((a, b) => a.start - b.start);
  const out: Interval[] = [];
  let cur = from;
  for (const b of xs) {
    if (b.start > cur) out.push({ start: cur, end: b.start });
    cur = Math.max(cur, b.end);
  }
  if (cur < to) out.push({ start: cur, end: to });
  return out.filter((s) => s.end - s.start >= minMinutes * MINUTE);
}

/** 長さ minutes の空き枠を from 以降・until 以前に count 個まで探す（刻みに合わせ、重ならない） */
export function findSlots(minutes: number, busy: readonly Interval[], from: EpochMs, until: EpochMs, count = 1, opts: PlanOptions = DEFAULT_PLAN): Interval[] {
  const out: Interval[] = [];
  const taken = [...busy];
  const dur = minutes * MINUTE;
  for (let day = startOfDay(from); day < until && out.length < count; day = addDays(day, 1)) {
    for (const s of freeSlots(day, taken, opts, from)) {
      let st = s.start;
      while (st + dur <= s.end && st + dur <= until && out.length < count) {
        const slot = { start: st, end: st + dur };
        out.push(slot);
        taken.push(slot);
        st = slot.end;
        break; // 同じ空きに詰め込まず、次の空きへ（余白を残す）
      }
      if (out.length >= count) break;
    }
  }
  return out;
}

// ---------------- 変更の提案（差分） ----------------

export interface Change {
  entity: 'task' | 'event' | 'subtask';
  id: string;
  title: string;
  before: { start: EpochMs | null; end: EpochMs | null };
  after: { start: EpochMs | null; end: EpochMs | null };
}

export interface NewSession { taskId: string; title: string; start: EpochMs; end: EpochMs }

export interface Proposal {
  id: string;
  title: string;
  /** なぜこの提案か（P09） */
  reason: string;
  changes: Change[];
  /** 作業枠（日時付きサブタスク）の追加 */
  sessions?: NewSession[];
  /** 期限を過ぎる・重なりが残るなどの注意 */
  warnings: string[];
  alternatives?: Proposal[];
}

const taskChange = (t: Task, start: EpochMs | null, end: EpochMs | null): Change => ({ entity: 'task', id: t.id, title: t.title, before: { start: t.plannedStart, end: t.plannedEnd }, after: { start, end } });

const md = (t: EpochMs) => { const d = new Date(t); return `${d.getMonth() + 1}/${d.getDate()} ${formatHm(t)}`; };

/** 期限より後になる場合の注意 */
function deadlineWarning(t: Task, end: EpochMs | null): string[] {
  const dl = deadlineOf(t);
  return dl != null && end != null && end > dl ? [`「${t.title}」の期限（${md(dl)}）より後になります。期限は変更しません`] : [];
}

/** P30：できなかったタスクを別の枠へ（期限は動かさない）。候補を複数返す */
export function postponeOptions(task: Task, busy: readonly BusyItem[], now: EpochMs, opts: PlanOptions = DEFAULT_PLAN): Proposal[] {
  const minutes = task.plannedStart != null && task.plannedEnd != null ? Math.round((task.plannedEnd - task.plannedStart) / MINUTE) : task.estimateMinutes ?? 30;
  const others = busy.filter((b) => !(b.kind === 'task' && b.refId === task.id));
  const out: Proposal[] = [];
  const later = findSlots(minutes, others, now, startOfDay(now) + 86_400_000, 1, opts)[0];
  if (later) out.push({ id: `postpone:${task.id}:later`, title: `今日の${formatHm(later.start)}から`, reason: `今日の空き時間のうち、いちばん早い${minutes}分の枠です`, changes: [taskChange(task, later.start, later.end)], warnings: deadlineWarning(task, later.end) });
  const tomorrow = addDays(startOfDay(now), 1);
  const sameTime = task.plannedStart != null ? { start: addDays(task.plannedStart, Math.max(1, Math.round((tomorrow - startOfDay(task.plannedStart)) / 86_400_000))), end: 0 } : null;
  if (sameTime) sameTime.end = sameTime.start + minutes * MINUTE;
  const tmr = sameTime && !others.some((o) => overlaps(o, sameTime)) ? sameTime : findSlots(minutes, others, tomorrow, addDays(tomorrow, 1), 1, opts)[0];
  if (tmr) out.push({ id: `postpone:${task.id}:tomorrow`, title: `明日の${formatHm(tmr.start)}から`, reason: sameTime && tmr === sameTime ? '明日の同じ時刻が空いています' : '明日の空き時間のうち、いちばん早い枠です', changes: [taskChange(task, tmr.start, tmr.end)], warnings: deadlineWarning(task, tmr.end) });
  out.push({ id: `postpone:${task.id}:inbox`, title: '日時を外して「未割当」へ', reason: 'いつやるかを後で決めます（期限はそのまま）', changes: [taskChange(task, null, null)], warnings: [] });
  return out;
}

/** P29・S05：作業時間を複数の作業枠（日時付きサブタスク）に分けて、期限までの空きに置く */
export function sessionsProposal(task: Task, totalMinutes: number, sessionMinutes: number, busy: readonly BusyItem[], now: EpochMs, until: EpochMs | null, opts: PlanOptions = DEFAULT_PLAN): Proposal | null {
  if (totalMinutes <= 0 || sessionMinutes <= 0) return null;
  const n = Math.max(1, Math.ceil(totalMinutes / sessionMinutes));
  const limit = until ?? addDays(startOfDay(now), 14);
  const per = Math.ceil(totalMinutes / n / 15) * 15;
  const slots = findSlots(per, busy, now, limit, n, opts);
  if (!slots.length) return null;
  const names = n === 1 ? ['作業'] : Array.from({ length: n }, (_, i) => (i === 0 ? '着手' : i === n - 1 ? '見直し' : `続き${i}`));
  const warnings = slots.length < n ? [`期限までに置けた作業枠は${slots.length}/${n}回です。残りは手動で決めてください`] : [];
  return {
    id: `sessions:${task.id}`,
    title: `${per}分×${slots.length}回に分けて置く`,
    reason: `残り${totalMinutes}分を${until ? `期限（${md(until)}）までの` : '2週間以内の'}空き時間に、間を空けて置きます`,
    changes: [],
    sessions: slots.map((s, i) => ({ taskId: task.id, title: `${names[i] ?? `作業${i + 1}`}`, start: s.start, end: s.end })),
    warnings,
  };
}

/** P05：1日の再計画。終わっていない・過ぎた・重なったタスクを、今より後の空きに順番に置き直す（予定は固定） */
export function replanDay(day: EpochMs, events: readonly Ev[], tasks: readonly Task[], subtasks: readonly Subtask[], now: EpochMs, filter?: (t: Task) => boolean, opts: PlanOptions = DEFAULT_PLAN): Proposal {
  const d0 = startOfDay(day);
  const d1 = addDays(d0, 1);
  const target = tasks
    .filter((t) => t.kind === 'do' && t.status === 'notStarted' && t.plannedStart != null && t.plannedEnd != null && t.plannedStart < d1 && t.plannedEnd > d0)
    .filter((t) => (filter ? filter(t) : true))
    .sort((a, b) => a.plannedStart! - b.plannedStart!);
  const busy = busyItems(events, tasks, subtasks);
  const fixed = busy.filter((b) => b.fixed);
  const keep = busy.filter((b) => !b.fixed && !target.some((t) => b.kind === 'task' && b.refId === t.id));
  const need = (t: Task) => t.plannedEnd! <= now || t.plannedStart! < now || fixed.some((f) => overlaps(f, { start: t.plannedStart!, end: t.plannedEnd! })) || !!filter;
  const moving = target.filter(need);
  const placed: Interval[] = [...fixed, ...keep];
  const changes: Change[] = [];
  const warnings: string[] = [];
  const startFrom = Math.max(now, d0);
  for (const t of moving) {
    const minutes = Math.round((t.plannedEnd! - t.plannedStart!) / MINUTE);
    const slot = findSlots(minutes, placed, startFrom, d1, 1, opts)[0] ?? findSlots(minutes, placed, d1, addDays(d1, 1), 1, opts)[0];
    if (!slot) { warnings.push(`「${t.title}」を置ける空きが今日・明日にありません`); continue; }
    placed.push(slot);
    changes.push(taskChange(t, slot.start, slot.end));
    warnings.push(...deadlineWarning(t, slot.end));
  }
  const tomorrowAlt: Proposal | undefined = moving.length ? (() => {
    const p2: Interval[] = [...fixed, ...keep];
    const ch: Change[] = [];
    for (const t of moving) {
      const minutes = Math.round((t.plannedEnd! - t.plannedStart!) / MINUTE);
      const s = findSlots(minutes, p2, d1, addDays(d1, 1), 1, opts)[0];
      if (s) { p2.push(s); ch.push(taskChange(t, s.start, s.end)); }
    }
    return ch.length ? { id: `replan:${d0}:tomorrow`, title: '明日に回す', reason: '今日は予定どおりの時間を空けておき、明日の空きに置きます', changes: ch, warnings: moving.flatMap((t) => deadlineWarning(t, ch.find((c) => c.id === t.id)?.after.end ?? null)) } : undefined;
  })() : undefined;
  return {
    id: `replan:${d0}`,
    title: changes.length ? `${changes.length}件を空き時間に置き直す` : '置き直すタスクはありません',
    reason: '時間の決まった予定は動かさず、終わっていないタスクを今より後の空きに順番に置きます',
    changes,
    warnings,
    ...(tomorrowAlt ? { alternatives: [tomorrowAlt] } : {}),
  };
}

/** P04：指定した分だけずらす差分と、つながっている準備タスク・重なりの影響 */
export function shiftProposal(entity: 'task' | 'event', item: { id: string; title: string; start: EpochMs; end: EpochMs }, deltaMin: number, tasks: readonly Task[], busy: readonly BusyItem[]): Proposal {
  const d = deltaMin * MINUTE;
  const changes: Change[] = [{ entity, id: item.id, title: item.title, before: { start: item.start, end: item.end }, after: { start: item.start + d, end: item.end + d } }];
  // 予定の準備タスク（sourceEventId でつながるもの）も同じだけ動かす
  if (entity === 'event') {
    for (const t of tasks.filter((x) => x.sourceEventId === item.id && x.plannedStart != null && x.plannedEnd != null && x.status === 'notStarted')) changes.push(taskChange(t, t.plannedStart! + d, t.plannedEnd! + d));
  }
  const moved = new Set(changes.map((c) => c.id));
  const hits = changes.flatMap((c) => busy.filter((b) => !moved.has(b.refId) && b.kind !== 'buffer' && overlaps(b, { start: c.after.start!, end: c.after.end! })).map((b) => b.title));
  return {
    id: `shift:${item.id}:${deltaMin}`,
    title: `${deltaMin > 0 ? `${deltaMin}分遅らせる` : `${-deltaMin}分早める`}`,
    reason: changes.length > 1 ? `つながっている準備${changes.length - 1}件も同じだけ動かします` : '対象だけを動かします',
    changes,
    warnings: [...new Set(hits)].map((h) => `「${h}」と重なります`),
  };
}

// ---------------- 問題の検知（P06〜P08・P36・P37・P39） ----------------

export type IssueKind = 'overlap' | 'duplicate' | 'travel' | 'lateRisk' | 'deadline' | 'unplanned' | 'overload' | 'dependency';

export interface Issue {
  id: string;
  kind: IssueKind;
  severity: 'info' | 'warn' | 'alert';
  title: string;
  reason: string;
  /** 根拠の確かさ（移動時間が未入力などは low） */
  confidence: 'high' | 'low';
  refs: { entity: 'event' | 'task'; id: string }[];
  proposals: Proposal[];
}

export interface IssueInput {
  events: readonly Ev[];
  tasks: readonly Task[];
  subtasks: readonly Subtask[];
  now: EpochMs;
  from: EpochMs;
  to: EpochMs;
  opts?: PlanOptions;
}

export function detectIssues({ events, tasks, subtasks, now, from, to, opts = DEFAULT_PLAN }: IssueInput): Issue[] {
  const out: Issue[] = [];
  const busy = busyItems(events, tasks, subtasks);
  const evs = events.filter((e) => !e.extra?.allDay && e.end > from && e.start < to && e.end > now - 6 * HOUR).sort((a, b) => a.start - b.start);

  // 二重登録（同じタイトル・同じ時間、または同じ勤務先の同じ時間）
  const seenDup = new Set<string>();
  for (let i = 0; i < evs.length; i++) for (let j = i + 1; j < evs.length; j++) {
    const a = evs[i]!; const b = evs[j]!;
    if (b.start > a.end) break;
    const sameTime = a.start === b.start && a.end === b.end;
    const sa = specOf(a); const sb = specOf(b);
    const sameShift = sa?.type === 'shift' && sb?.type === 'shift' && overlaps(a, b) && (a.employerId ?? sa.details.workplace) === (b.employerId ?? sb.details.workplace);
    if ((sameTime && a.title.trim() === b.title.trim()) || sameShift) {
      const k = [a.id, b.id].sort().join('|');
      if (seenDup.has(k)) continue;
      seenDup.add(k);
      out.push({ id: `dup:${k}`, kind: 'duplicate', severity: 'warn', title: `「${a.title}」が二重に登録されている可能性`, reason: sameShift ? '同じ勤務先の勤務が同じ時間に2件あります（給与の見込みは1回分だけ数えます）' : '同じタイトル・同じ時間の予定が2件あります', confidence: 'high', refs: [{ entity: 'event', id: a.id }, { entity: 'event', id: b.id }], proposals: [] });
    }
  }
  // 予定どうしの重なり（自動では動かさない）
  for (let i = 0; i < evs.length; i++) for (let j = i + 1; j < evs.length; j++) {
    const a = evs[i]!; const b = evs[j]!;
    if (b.start >= a.end) break;
    const k = [a.id, b.id].sort().join('|');
    if (seenDup.has(k)) continue;
    out.push({ id: `ovl:${k}`, kind: 'overlap', severity: 'warn', title: `「${a.title}」と「${b.title}」が重なっています`, reason: `${formatHm(b.start)}〜${formatHm(Math.min(a.end, b.end))}が重なります。時間の決まった予定は自動で動かしません`, confidence: 'high', refs: [{ entity: 'event', id: a.id }, { entity: 'event', id: b.id }], proposals: [] });
  }
  // タスクと予定の重なり → タスクだけを空きへ動かす提案
  for (const t of tasks) {
    if (t.kind !== 'do' || t.status !== 'notStarted' || t.plannedStart == null || t.plannedEnd == null || t.plannedEnd <= now || t.plannedStart >= to || t.plannedEnd <= from) continue;
    const hit = evs.find((e) => e.id !== t.eventId && overlaps(e, { start: t.plannedStart!, end: t.plannedEnd! }));
    if (!hit) continue;
    const minutes = Math.round((t.plannedEnd - t.plannedStart) / MINUTE);
    const others = busy.filter((b) => !(b.kind === 'task' && b.refId === t.id));
    const slots = findSlots(minutes, others, Math.max(now, startOfDay(t.plannedStart)), addDays(startOfDay(t.plannedStart), 2), 2, opts);
    out.push({
      id: `tovl:${t.id}`, kind: 'overlap', severity: 'warn', title: `「${t.title}」が「${hit.title}」と重なっています`, reason: '予定の時間にはタスクを進めにくいため、空き時間への移動を提案します', confidence: 'high', refs: [{ entity: 'task', id: t.id }, { entity: 'event', id: hit.id }],
      proposals: slots.map((s, i) => ({ id: `tovl:${t.id}:${i}`, title: `${md(s.start)}〜${formatHm(s.end)}へ移す`, reason: i === 0 ? '重ならない最初の空きです' : '別の候補です', changes: [taskChange(t, s.start, s.end)], warnings: deadlineWarning(t, s.end) })),
    });
  }
  // 移動時間の不足・遅刻の恐れ（P07・P39）
  for (let i = 1; i < evs.length; i++) {
    const prev = evs[i - 1]!; const next = evs[i]!;
    if (next.start <= now || next.start < prev.end) continue;
    const gap = Math.round((next.start - prev.end) / MINUTE);
    if (gap > 180) continue;
    const travel = next.extra?.travelMinutes ?? null;
    const placeA = prev.extra?.place?.name ?? ''; const placeB = next.extra?.place?.name ?? '';
    if (travel != null && travel > gap) out.push({ id: `travel:${prev.id}:${next.id}`, kind: 'travel', severity: 'alert', title: `「${next.title}」に間に合わない恐れ`, reason: `「${prev.title}」の終了から${gap}分しかありません（移動に${travel}分）`, confidence: 'high', refs: [{ entity: 'event', id: prev.id }, { entity: 'event', id: next.id }], proposals: [] });
    else if (travel == null && placeA && placeB && placeA !== placeB && gap < 60) out.push({ id: `travel?:${prev.id}:${next.id}`, kind: 'travel', severity: 'info', title: `「${next.title}」までの移動時間が未入力`, reason: `場所が「${placeA}」から「${placeB}」に変わり、間が${gap}分です。経路が分からないため確かではありません`, confidence: 'low', refs: [{ entity: 'event', id: next.id }], proposals: [] });
  }
  // 遅れているタスクが次の予定にかかる
  for (const t of tasks) {
    if (t.kind !== 'do' || t.status !== 'running') continue;
    const eta = estimateEnd(t, subtasks.filter((s) => s.taskId === t.id), now);
    const end = eta.kind === 'estimate' ? eta.at : delayInfo(t, now).delayed ? now : null;
    if (end == null) continue;
    const next = evs.find((e) => e.start > now && e.start < end + (e.extra?.travelMinutes ?? 0) * MINUTE);
    if (next) out.push({ id: `late:${t.id}:${next.id}`, kind: 'lateRisk', severity: 'warn', title: `「${t.title}」が「${next.title}」にかかりそう`, reason: eta.kind === 'estimate' ? `実績から見た終了の見込みは${formatHm(eta.at)}です` : '予定の終了を過ぎて続いています', confidence: eta.kind === 'estimate' ? 'high' : 'low', refs: [{ entity: 'task', id: t.id }, { entity: 'event', id: next.id }], proposals: [] });
  }
  // 期限に対して時間が足りない・まだ作業時間を決めていない（P08・P36）
  for (const t of tasks) {
    if (t.status === 'done' || t.checked) continue;
    const dl = deadlineOf(t);
    if (dl == null || dl <= now || dl > to + 14 * 86_400_000) continue;
    const rem = t.estimateMinutes != null ? Math.max(0, t.estimateMinutes - Math.round(workedMs(t, now) / MINUTE)) : null;
    if (rem == null || rem === 0) continue;
    const subs = subtasks.filter((s) => s.taskId === t.id);
    const planned = (t.plannedStart != null && t.plannedEnd != null && t.plannedEnd > now ? Math.round((t.plannedEnd - Math.max(now, t.plannedStart)) / MINUTE) : 0)
      + subs.filter((s) => !s.done && s.plannedStart != null && s.plannedEnd != null && s.plannedEnd > now).reduce((m, s) => m + Math.round((s.plannedEnd! - Math.max(now, s.plannedStart!)) / MINUTE), 0);
    const free = Array.from({ length: Math.max(1, Math.ceil((dl - startOfDay(now)) / 86_400_000)) }, (_, i) => freeSlots(addDays(startOfDay(now), i), busy, opts, now)).flat().filter((s) => s.start < dl).reduce((m, s) => m + Math.round((Math.min(s.end, dl) - s.start) / MINUTE), 0);
    const needMore = rem - planned;
    if (needMore <= 0) continue;
    const p = sessionsProposal(t, needMore, Math.min(60, needMore), busy, now, dl, opts);
    if (free + planned < rem) out.push({ id: `dl:${t.id}`, kind: 'deadline', severity: 'alert', title: `「${t.title}」は期限までに時間が足りない見込み`, reason: `残りの作業${rem}分（見込み）に対し、期限までの空きは約${free}分です。期限は変えません`, confidence: 'low', refs: [{ entity: 'task', id: t.id }], proposals: p ? [p] : [] });
    else if (dl - now < 3 * 86_400_000) out.push({ id: `plan:${t.id}`, kind: 'unplanned', severity: 'warn', title: `「${t.title}」の作業時間がまだ決まっていません`, reason: `期限（${md(dl)}）まで${Math.ceil((dl - now) / 86_400_000)}日、残り${needMore}分（見込み）を空き時間に置けます`, confidence: 'high', refs: [{ entity: 'task', id: t.id }], proposals: p ? [p] : [] });
  }
  // 前のタスクが終わっていない（P28）
  const byId = new Map(tasks.map((t) => [t.id, t]));
  for (const t of tasks) {
    const deps = (t.extra?.dependsOn ?? []).map((id) => byId.get(id)).filter((x): x is Task => !!x && x.status !== 'done' && !x.checked);
    if (!deps.length || t.status === 'done' || t.plannedStart == null || t.plannedStart >= to || t.plannedStart < from) continue;
    out.push({ id: `dep:${t.id}`, kind: 'dependency', severity: 'info', title: `「${t.title}」の前に終えるタスクがあります`, reason: `${deps.map((d) => `「${d.title}」`).join('、')}が未完了です`, confidence: 'high', refs: [{ entity: 'task', id: t.id }, ...deps.map((d) => ({ entity: 'task' as const, id: d.id }))], proposals: [] });
  }
  // 詰め込み（1日の予定とタスクが活動時間の85%を超える：P37）
  for (let d = startOfDay(from); d < to; d = addDays(d, 1)) {
    const win = (opts.toHour - opts.fromHour) * 60;
    const used = unionMinutes(busy, d + opts.fromHour * HOUR, d + opts.toHour * HOUR);
    if (used / win > 0.85) out.push({ id: `load:${d}`, kind: 'overload', severity: 'info', title: `${new Date(d).getMonth() + 1}/${new Date(d).getDate()}は予定が詰まっています`, reason: `${opts.fromHour}〜${opts.toHour}時の${Math.round((used / win) * 100)}%が埋まっています。休む時間も残しましょう`, confidence: 'high', refs: [], proposals: [] });
  }
  const rank = { alert: 0, warn: 1, info: 2 } as const;
  return out.sort((a, b) => rank[a.severity] - rank[b.severity]);
}

// ---------------- 次の行動（P24） ----------------

export interface NextAction {
  kind: 'continue' | 'start' | 'leave' | 'event' | 'plan' | 'free';
  title: string;
  detail: string;
  ref: { entity: 'task' | 'event'; id: string } | null;
  at: EpochMs | null;
}

export function nextAction(events: readonly Ev[], tasks: readonly Task[], now: EpochMs): NextAction {
  const running = tasks.find((t) => t.kind === 'do' && t.status === 'running');
  if (running) return { kind: 'continue', title: running.title, detail: '実行中', ref: { entity: 'task', id: running.id }, at: null };
  const due = tasks
    .filter((t) => t.kind === 'do' && t.status === 'notStarted' && t.plannedStart != null && t.plannedEnd != null && t.plannedEnd > now && t.plannedStart <= now + 30 * MINUTE)
    .sort((a, b) => a.plannedStart! - b.plannedStart!)[0];
  const ev = events.filter((e) => !e.extra?.allDay && e.start > now && e.start < now + 3 * HOUR).sort((a, b) => a.start - b.start)[0];
  if (ev?.extra?.travelMinutes) {
    const leave = ev.start - ev.extra.travelMinutes * MINUTE;
    if (leave - now <= 30 * MINUTE && (!due || leave <= due.plannedStart!)) return { kind: 'leave', title: ev.title, detail: leave <= now ? '出発の時刻です' : `${formatHm(leave)}に出発（移動${ev.extra.travelMinutes}分）`, ref: { entity: 'event', id: ev.id }, at: leave };
  }
  if (due) return { kind: 'start', title: due.title, detail: due.plannedStart! <= now ? `${formatHm(due.plannedStart!)}開始の予定` : `${formatHm(due.plannedStart!)}から`, ref: { entity: 'task', id: due.id }, at: due.plannedStart };
  const nowEv = events.find((e) => !e.extra?.allDay && e.start <= now && e.end > now);
  if (nowEv) return { kind: 'event', title: nowEv.title, detail: `${formatHm(nowEv.end)}まで`, ref: { entity: 'event', id: nowEv.id }, at: nowEv.end };
  const upcomingTask = tasks.filter((t) => t.kind === 'do' && t.status === 'notStarted' && t.plannedStart != null && t.plannedStart > now && t.plannedStart < startOfDay(now) + 86_400_000).sort((a, b) => a.plannedStart! - b.plannedStart!)[0];
  const cands: NextAction[] = [];
  if (upcomingTask) cands.push({ kind: 'start', title: upcomingTask.title, detail: `${formatHm(upcomingTask.plannedStart!)}から`, ref: { entity: 'task', id: upcomingTask.id }, at: upcomingTask.plannedStart });
  if (ev) cands.push({ kind: 'event', title: ev.title, detail: `${formatHm(ev.start)}から`, ref: { entity: 'event', id: ev.id }, at: ev.start });
  cands.sort((a, b) => (a.at ?? 0) - (b.at ?? 0));
  if (cands[0]) return cands[0];
  const inbox = tasks.filter((t) => t.status !== 'done' && !t.checked && t.kind === 'do' && t.plannedStart == null).map((t) => ({ t, dl: deadlineOf(t) })).sort((a, b) => (a.dl ?? Infinity) - (b.dl ?? Infinity))[0];
  if (inbox) return { kind: 'plan', title: inbox.t.title, detail: inbox.dl != null ? `期限 ${md(inbox.dl)}・時間を決めましょう` : 'いつやるか決めていません', ref: { entity: 'task', id: inbox.t.id }, at: null };
  return { kind: 'free', title: 'この後の予定はありません', detail: '自由に過ごせる時間です', ref: null, at: null };
}

// ---------------- 振り返り（P31〜P40） ----------------

/** P32：活動時間帯のうち、予定・タスク・移動で埋まっていない割合（重なりは1回だけ数える） */
export function freeTime(day: EpochMs, busy: readonly BusyItem[], opts: PlanOptions = DEFAULT_PLAN): { busyMinutes: number; freeMinutes: number; ratio: number } {
  const d0 = startOfDay(day);
  const win = (opts.toHour - opts.fromHour) * 60;
  const used = unionMinutes(busy, d0 + opts.fromHour * HOUR, d0 + opts.toHour * HOUR);
  return { busyMinutes: used, freeMinutes: win - used, ratio: win ? (win - used) / win : 0 };
}

/** P33：期限の集中（今日から days 日。同じ日に2件以上を集中とする） */
export function deadlineCrowd(tasks: readonly Task[], now: EpochMs, days = 14): { day: EpochMs; tasks: Task[] }[] {
  const d0 = startOfDay(now);
  const out = Array.from({ length: days }, (_, i) => ({ day: addDays(d0, i), tasks: [] as Task[] }));
  for (const t of tasks) {
    if (t.status === 'done' || t.checked) continue;
    const dl = deadlineOf(t);
    if (dl == null || dl < d0) continue;
    const i = Math.floor((startOfDay(dl) - d0) / 86_400_000);
    if (i >= 0 && i < days) out[i]!.tasks.push(t);
  }
  return out;
}

/** P35・S03：勤務先別の給与見込み（税引前・交通費は別に合計） */
export function payForecast(events: readonly Ev[], employers: readonly Employer[], from: EpochMs, to: EpochMs): { workplace: string; shifts: number; minutes: number; pay: number; transport: number; missingWage: number }[] {
  const by = new Map<string, { workplace: string; shifts: number; minutes: number; pay: number; transport: number; missingWage: number }>();
  const seen = new Set<string>();
  for (const e of events) {
    if (e.start < from || e.start >= to) continue;
    const s = specOf(e);
    if (s?.type !== 'shift') continue;
    const wp = workplaceOf(e, s, employers) || '勤務先未設定';
    const key = `${wp}|${e.start}|${e.end}`;
    if (seen.has(key)) continue; // 二重登録は1回分だけ
    seen.add(key);
    const row = by.get(wp) ?? { workplace: wp, shifts: 0, minutes: 0, pay: 0, transport: 0, missingWage: 0 };
    const p = shiftPay(e.start, e.end, num(s.details.hourlyWage), num(s.details.breakMinutes));
    row.shifts += 1;
    row.minutes += p?.workMinutes ?? Math.round((e.end - e.start) / MINUTE);
    if (p) row.pay += p.pay; else row.missingWage += 1;
    row.transport += num(s.details.transportFee) ?? 0;
    by.set(wp, row);
  }
  return [...by.values()];
}

/** P36：締切のあるタスクの残り負荷（残りの作業と、期限までの空き） */
export function remainingLoad(tasks: readonly Task[], busy: readonly BusyItem[], now: EpochMs, opts: PlanOptions = DEFAULT_PLAN): { task: Task; due: EpochMs; remaining: number; free: number }[] {
  const out: { task: Task; due: EpochMs; remaining: number; free: number }[] = [];
  for (const t of tasks) {
    if (t.status === 'done' || t.checked || t.estimateMinutes == null) continue;
    const dl = deadlineOf(t);
    if (dl == null || dl <= now) continue;
    const remaining = Math.max(0, t.estimateMinutes - Math.round(workedMs(t, now) / MINUTE));
    const days = Math.min(30, Math.ceil((dl - startOfDay(now)) / 86_400_000));
    const free = Array.from({ length: days }, (_, i) => freeSlots(addDays(startOfDay(now), i), busy, opts, now)).flat().filter((s) => s.start < dl).reduce((m, s) => m + Math.round((Math.min(s.end, dl) - s.start) / MINUTE), 0);
    out.push({ task: t, due: dl, remaining, free });
  }
  return out.sort((a, b) => a.due - b.due);
}

/** P37：日別の拘束時間。確定（予定）と見込み（タスク・作業枠）を分ける */
export function loadHeatmap(events: readonly Ev[], tasks: readonly Task[], subtasks: readonly Subtask[], from: EpochMs, days: number): { day: EpochMs; fixedMinutes: number; taskMinutes: number }[] {
  const busy = busyItems(events, tasks, subtasks);
  return Array.from({ length: days }, (_, i) => {
    const d = addDays(startOfDay(from), i);
    const e = addDays(d, 1);
    return { day: d, fixedMinutes: unionMinutes(busy.filter((b) => b.fixed), d, e), taskMinutes: unionMinutes(busy.filter((b) => !b.fixed), d, e) };
  });
}

/** P38：完了した作業の時間帯の傾向。完了が5件未満なら出さない */
export function focusHours(tasks: readonly Task[], from: EpochMs, to: EpochMs): { hours: number[]; best: number | null; samples: number } | null {
  const done = tasks.filter((t) => t.status === 'done' && t.actualEnd != null && t.actualEnd >= from && t.actualEnd < to);
  if (done.length < 5) return null;
  const hours = Array.from({ length: 24 }, () => 0);
  for (const t of done) for (const iv of t.intervals) {
    const end = iv.end ?? iv.start;
    for (let s = iv.start; s < end; s += 15 * MINUTE) hours[new Date(s).getHours()]! += 15;
  }
  const max = Math.max(...hours);
  return { hours, best: max > 0 ? hours.indexOf(max) : null, samples: done.length };
}

/** P26：見積と実績の比（同じ種類・カテゴリーの完了タスク）。3件未満は学習しない */
export function estimateLearning(tasks: readonly Task[], target: Pick<Task, 'id' | 'category'> & { extra?: Task['extra'] }, now: EpochMs): { ratio: number; samples: number } | null {
  const key = (t: Pick<Task, 'category'> & { extra?: Task['extra'] }) => `${(t.extra?.spec as { type?: string } | null | undefined)?.type ?? ''}|${t.category ?? ''}`;
  const k = key(target);
  const xs = tasks
    .filter((t) => t.id !== target.id && t.status === 'done' && t.estimateMinutes != null && t.estimateMinutes > 0 && key(t) === k)
    .map((t) => workedMs(t, t.actualEnd ?? now) / MINUTE / t.estimateMinutes!)
    .filter((r) => r > 0.05 && r < 10)
    .sort((a, b) => a - b);
  if (xs.length < 3) return null;
  return { ratio: xs[Math.floor(xs.length / 2)]!, samples: xs.length };
}

/** P34：生活の分類別の時間（予定の長さ＋タスクの作業時間）。分類は種類から決め、種類を変えれば直せる */
export function lifeAllocation(events: readonly Ev[], tasks: readonly Task[], from: EpochMs, to: EpochMs, now: EpochMs, calendarKind: (e: Ev) => 'general' | 'class' | 'job' = () => 'general'): { group: SpecGroup | 'other'; minutes: number }[] {
  const by = new Map<SpecGroup | 'other', number>();
  const add = (g: SpecGroup | 'other', m: number) => by.set(g, (by.get(g) ?? 0) + m);
  for (const e of events) {
    if (e.extra?.allDay || e.end <= from || e.start >= to) continue;
    const s = specOf(e, calendarKind(e));
    add(s ? SPEC_BY_ID[s.type].group : 'other', Math.round((Math.min(e.end, to) - Math.max(e.start, from)) / MINUTE));
  }
  for (const t of tasks) {
    const m = Math.round(t.intervals.reduce((s, iv) => s + Math.max(0, Math.min(iv.end ?? now, to) - Math.max(iv.start, from)), 0) / MINUTE);
    if (!m) continue;
    const s = specOf(t);
    add(s ? SPEC_BY_ID[s.type].group : 'other', m);
  }
  return [...by.entries()].map(([group, minutes]) => ({ group, minutes })).filter((x) => x.minutes > 0).sort((a, b) => b.minutes - a.minutes);
}

/** P40：1日の振り返りと翌日の提案 */
export function dayReview(day: EpochMs, events: readonly Ev[], tasks: readonly Task[], subtasks: readonly Subtask[], now: EpochMs, opts: PlanOptions = DEFAULT_PLAN) {
  const d0 = startOfDay(day);
  const d1 = addDays(d0, 1);
  const todays = tasks.filter((t) => t.kind === 'do' && t.plannedStart != null && t.plannedStart >= d0 && t.plannedStart < d1);
  const done = todays.filter((t) => t.status === 'done');
  const unfinished = todays.filter((t) => t.status !== 'done');
  const tomorrowFixed = events.filter((e) => e.start >= d1 && e.start < addDays(d1, 1)).sort((a, b) => a.start - b.start);
  const busy = busyItems(events, tasks, subtasks);
  const moves: Change[] = [];
  const placed: Interval[] = busy.filter((b) => !unfinished.some((t) => b.refId === t.id));
  for (const t of unfinished.filter((x) => x.status === 'notStarted')) {
    const minutes = Math.round((t.plannedEnd! - t.plannedStart!) / MINUTE);
    const s = findSlots(minutes, placed, d1, addDays(d1, 1), 1, opts)[0];
    if (s) { placed.push(s); moves.push(taskChange(t, s.start, s.end)); }
  }
  const proposal: Proposal | null = moves.length ? { id: `review:${d0}`, title: `未完了${moves.length}件を明日の空きへ`, reason: '明日の予定を避けて、空いている時間に置きます', changes: moves, warnings: unfinished.flatMap((t) => deadlineWarning(t, moves.find((m) => m.id === t.id)?.after.end ?? null)) } : null;
  return { done, unfinished, tomorrowFixed, worked: Math.round(todays.reduce((s, t) => s + workedMs(t, now), 0) / MINUTE), proposal, free: freeTime(d1, busy, opts) };
}

/** P28：前提のタスクが未完了か */
export function blockingTasks(task: Task, tasks: readonly Task[]): Task[] {
  const ids = task.extra?.dependsOn ?? [];
  return tasks.filter((t) => ids.includes(t.id) && t.status !== 'done' && !t.checked);
}

/** S25：自由時間の候補。1日の空きの7割以上は残す（埋め尽くさない） */
export function leisureSuggestion(day: EpochMs, busy: readonly BusyItem[], minutes: number, now: EpochMs, opts: PlanOptions = DEFAULT_PLAN): Interval | null {
  const f = freeTime(day, busy, opts);
  if (f.freeMinutes - minutes < f.freeMinutes * 0.7 && f.freeMinutes < 240) return null;
  return findSlots(minutes, busy, Math.max(now, startOfDay(day)), addDays(startOfDay(day), 1), 1, opts)[0] ?? null;
}

/** 予定の前に並べる準備（S01・S14・S15）：開始（移動を引いた時刻）の直前から逆に並べる */
export function prepBefore(eventStart: EpochMs, travelMinutes: number | null, items: { title: string; minutes: number }[]): { title: string; start: EpochMs; end: EpochMs }[] {
  let end = eventStart - (travelMinutes ?? 0) * MINUTE;
  const out: { title: string; start: EpochMs; end: EpochMs }[] = [];
  for (const it of [...items].reverse()) {
    const start = end - it.minutes * MINUTE;
    out.unshift({ title: it.title, start, end });
    end = start;
  }
  return out;
}

export function specLabel(type: SpecTypeId): string {
  return SPEC_BY_ID[type].name;
}
