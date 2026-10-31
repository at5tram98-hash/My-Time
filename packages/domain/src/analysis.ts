import type { EpochMs, Task } from './types';
import { addDays } from './time';
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
