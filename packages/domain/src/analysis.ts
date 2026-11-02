import type { EpochMs, Task } from './types';
import { addDays, addMonths, fromWall, HOUR, MINUTE, startOfDay, wall, weekdayJa } from './time';
import { tasksForDay } from './agenda';
import { workedMs } from './progress';

export interface AnalysisOptions {
  /** 一時停止を経験したタスクを含める（初期値 false） */
  includePaused: boolean;
  /** 自動開始/終了（AR）したタスクを含める（初期値 false） */
  includeAuto: boolean;
}

export const DEFAULT_ANALYSIS: AnalysisOptions = { includePaused: false, includeAuto: false };

export interface DayStats {
  day: EpochMs;
  total: number;
  done: number;
  /** 完了率（対象0件なら null） */
  completionRate: number | null;
  /** 遅延の判定対象（予定終了を過ぎた、または完了したもの） */
  delayBase: number;
  delayed: number;
  delayRate: number | null;
  workedMs: number;
  excluded: number;
}

/**
 * 1日の集計。対象は時刻指定された「実施」タスクのみ（授業・アルバイトなどの予定は含まない）。
 * 遅延 = 予定終了より後に完了した、または未完了のまま予定終了を過ぎたもの。
 */
export function dayStats(tasks: readonly Task[], day: EpochMs, now: EpochMs, opts: AnalysisOptions = DEFAULT_ANALYSIS): DayStats {
  const all = tasksForDay(tasks, day).filter((t) => t.kind === 'do');
  const eligible = all.filter((t) => (opts.includePaused || !t.pausedEver) && (opts.includeAuto || !t.autoReserved));
  const done = eligible.filter((t) => t.status === 'done');
  const base = eligible.filter((t) => t.status === 'done' || (t.plannedEnd != null && now > t.plannedEnd));
  const delayed = base.filter((t) => t.plannedEnd != null && (t.status === 'done' ? (t.actualEnd ?? 0) > t.plannedEnd : now > t.plannedEnd));
  return {
    day,
    total: eligible.length,
    done: done.length,
    completionRate: eligible.length ? done.length / eligible.length : null,
    delayBase: base.length,
    delayed: delayed.length,
    delayRate: base.length ? delayed.length / base.length : null,
    workedMs: eligible.reduce((s, t) => s + workedMs(t, now), 0),
    excluded: all.length - eligible.length,
  };
}

export function weekStats(tasks: readonly Task[], weekStart: EpochMs, now: EpochMs, opts: AnalysisOptions = DEFAULT_ANALYSIS): { days: DayStats[]; total: Omit<DayStats, 'day'> } {
  const days = Array.from({ length: 7 }, (_, i) => dayStats(tasks, addDays(weekStart, i), now, opts));
  const sum = days.reduce(
    (a, d) => ({ total: a.total + d.total, done: a.done + d.done, delayBase: a.delayBase + d.delayBase, delayed: a.delayed + d.delayed, workedMs: a.workedMs + d.workedMs, excluded: a.excluded + d.excluded }),
    { total: 0, done: 0, delayBase: 0, delayed: 0, workedMs: 0, excluded: 0 },
  );
  return {
    days,
    total: { ...sum, completionRate: sum.total ? sum.done / sum.total : null, delayRate: sum.delayBase ? sum.delayed / sum.delayBase : null },
  };
}

// ---------------------------------------------------------------------------
// UI/UX v2 分析（Q42〜51）：日・週・月・年の期間集計
// ---------------------------------------------------------------------------

export type AnalysisPeriod = 'day' | 'week' | 'month' | 'year';

export interface PeriodRange { period: AnalysisPeriod; from: EpochMs; to: EpochMs }

/** anchor を含む期間（週は日曜はじまり） */
export function periodRange(period: AnalysisPeriod, anchor: EpochMs): PeriodRange {
  const d = startOfDay(anchor);
  const w = wall(d);
  if (period === 'day') return { period, from: d, to: addDays(d, 1) };
  if (period === 'week') { const from = addDays(d, -w.wd); return { period, from, to: addDays(from, 7) }; }
  if (period === 'month') { const from = fromWall(w.y, w.mo, 1); return { period, from, to: fromWall(w.y, w.mo + 1, 1) }; }
  const from = fromWall(w.y, 0, 1);
  return { period, from, to: fromWall(w.y + 1, 0, 1) };
}

/** n 期間ずらす */
export function shiftPeriod(r: PeriodRange, n: number): PeriodRange {
  if (r.period === 'day') return periodRange('day', addDays(r.from, n));
  if (r.period === 'week') return periodRange('week', addDays(r.from, 7 * n));
  if (r.period === 'month') return periodRange('month', addMonths(r.from, n));
  return periodRange('year', addMonths(r.from, 12 * n));
}

export function periodLabel(r: PeriodRange): string {
  const a = wall(r.from);
  const b = wall(addDays(r.to, -1));
  if (r.period === 'day') return `${a.y}年${a.mo + 1}月${a.d}日（${weekdayJa(r.from)}）`;
  if (r.period === 'week') return `${a.mo + 1}月${a.d}日〜${b.mo + 1 === a.mo + 1 ? '' : `${b.mo + 1}月`}${b.d}日`;
  if (r.period === 'month') return `${a.y}年${a.mo + 1}月`;
  return `${a.y}年`;
}

export interface Bucket { from: EpochMs; to: EpochMs; label: string }

/** グラフの区切り：日→3時間ごと、週→曜日、月→日、年→月 */
export function periodBuckets(r: PeriodRange): Bucket[] {
  const out: Bucket[] = [];
  if (r.period === 'day') {
    for (let h = 0; h < 24; h += 3) out.push({ from: r.from + h * HOUR, to: r.from + (h + 3) * HOUR, label: `${h}時` });
    return out;
  }
  if (r.period === 'year') {
    for (let m = 0; m < 12; m++) { const from = addMonths(r.from, m); out.push({ from, to: addMonths(r.from, m + 1), label: `${m + 1}月` }); }
    return out;
  }
  for (let t = r.from; t < r.to; t = addDays(t, 1)) out.push({ from: t, to: addDays(t, 1), label: r.period === 'week' ? weekdayJa(t) : `${wall(t).d}` });
  return out;
}

/** 区間 [from,to) に重なる作業時間（実行中は now まで）。期間ごとに切り分けるので二重計上しない */
export function workedInRange(task: Pick<Task, 'intervals'>, from: EpochMs, to: EpochMs, now: EpochMs): number {
  let sum = 0;
  for (const iv of task.intervals) {
    const s = Math.max(iv.start, from);
    const e = Math.min(iv.end ?? now, to, now);
    if (e > s) sum += e - s;
  }
  return sum;
}

export interface PeriodStats {
  total: number;
  done: number;
  completionRate: number | null;
  delayBase: number;
  delayed: number;
  delayRate: number | null;
  workedMs: number;
  /** 完了したタスクの（実行時間 − 予定時間）の合計。正なら予定より長くかかった */
  planDiffMs: number;
  planDiffCount: number;
  /** 一時停止→再開の回数（中断） */
  interruptions: number;
  excluded: number;
  byWeekday: number[];
  byHour: number[];
  buckets: { from: EpochMs; label: string; workedMs: number; total: number; done: number; completionRate: number | null }[];
  /** 期間内に予定されていたタスク（詳細表示用） */
  taskIds: string[];
}

function anchorOf(t: Task): EpochMs | null {
  return t.kind === 'check' ? t.checkAt : t.plannedStart;
}

/**
 * 期間の集計。対象は時刻指定された「実施」タスク。
 * 件数は予定開始の日時で1回だけ数え（複数日にまたがっても二重に数えない）、
 * 実行時間は実際に作業した時刻で期間に振り分ける。
 */
export function periodStats(tasks: readonly Task[], r: PeriodRange, now: EpochMs, opts: AnalysisOptions = DEFAULT_ANALYSIS): PeriodStats {
  const doTasks = tasks.filter((t) => t.kind === 'do');
  const ok = (t: Task) => (opts.includePaused || !t.pausedEver) && (opts.includeAuto || !t.autoReserved);
  const inRange = (t: Task) => { const a = anchorOf(t); return a != null && a >= r.from && a < r.to; };
  const all = doTasks.filter(inRange);
  const eligible = all.filter(ok);
  const working = doTasks.filter(ok);
  const isDelayed = (t: Task) => t.plannedEnd != null && (t.status === 'done' ? (t.actualEnd ?? 0) > t.plannedEnd : now > t.plannedEnd);
  const base = eligible.filter((t) => t.status === 'done' || (t.plannedEnd != null && now > t.plannedEnd));
  const delayed = base.filter(isDelayed);
  const done = eligible.filter((t) => t.status === 'done');
  let planDiffMs = 0;
  let planDiffCount = 0;
  for (const t of done) {
    if (t.plannedStart == null || t.plannedEnd == null) continue;
    planDiffMs += workedMs(t, now) - (t.plannedEnd - t.plannedStart);
    planDiffCount++;
  }
  const byWeekday = Array<number>(7).fill(0);
  const byHour = Array<number>(24).fill(0);
  let worked = 0;
  for (const t of working) {
    for (const iv of t.intervals) {
      let s = Math.max(iv.start, r.from);
      const e = Math.min(iv.end ?? now, r.to, now);
      worked += Math.max(0, e - s);
      // 1時間ごとに切って曜日・時間帯へ振り分ける
      while (s < e) {
        const w = wall(s);
        const next = Math.min(e, s + (HOUR - ((w.mi * MINUTE + w.s * 1000 + w.ms) % HOUR)));
        byWeekday[w.wd]! += next - s;
        byHour[w.h]! += next - s;
        s = next;
      }
    }
  }
  const buckets = periodBuckets(r).map((b) => {
    const ts = eligible.filter((t) => { const a = anchorOf(t)!; return a >= b.from && a < b.to; });
    const d = ts.filter((t) => t.status === 'done').length;
    return { from: b.from, label: b.label, workedMs: working.reduce((s, t) => s + workedInRange(t, b.from, b.to, now), 0), total: ts.length, done: d, completionRate: ts.length ? d / ts.length : null };
  });
  return {
    total: eligible.length,
    done: done.length,
    completionRate: eligible.length ? done.length / eligible.length : null,
    delayBase: base.length,
    delayed: delayed.length,
    delayRate: base.length ? delayed.length / base.length : null,
    workedMs: worked,
    planDiffMs,
    planDiffCount,
    interruptions: eligible.reduce((s, t) => s + Math.max(0, t.intervals.length - 1), 0),
    excluded: all.length - eligible.length,
    byWeekday,
    byHour,
    buckets,
    taskIds: eligible.map((t) => t.id),
  };
}
