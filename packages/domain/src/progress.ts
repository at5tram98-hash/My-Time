import type { EpochMs, Subtask, Task } from './types';
import { MINUTE } from './time';

const clamp01 = (v: number) => Math.min(1, Math.max(0, v));

/** 予定時間に対する理想進捗（自動計算）。予定時刻がなければ null。 */
export function idealProgress(task: Pick<Task, 'plannedStart' | 'plannedEnd'>, now: EpochMs): number | null {
  const { plannedStart, plannedEnd } = task;
  if (plannedStart == null || plannedEnd == null || plannedEnd <= plannedStart) return null;
  return clamp01((now - plannedStart) / (plannedEnd - plannedStart));
}

/** 累積作業時間（実行中の区間は now まで） */
export function workedMs(task: Pick<Task, 'intervals'>, at: EpochMs): number {
  let sum = 0;
  for (const iv of task.intervals) {
    const end = iv.end ?? at;
    const s = Math.min(iv.start, at);
    const e = Math.min(end, at);
    if (e > s) sum += e - s;
  }
  return sum;
}

/** サブタスクの完了数による等分進捗。サブタスクがなければ null。 */
export function subtaskProgress(subtasks: readonly Subtask[]): number | null {
  if (subtasks.length === 0) return null;
  return subtasks.filter((s) => s.done).length / subtasks.length;
}

export type ProgressSource = 'subtasks' | 'manual' | 'none';

export interface ActualProgress {
  value: number | null;
  source: ProgressSource;
  /** ETA計算の根拠となる最新の実績時点 */
  sampleAt: EpochMs | null;
}

/** 実績進捗。サブタスクを持つ親はサブタスクのみが根拠（手動入力は無効）。 */
export function actualProgress(task: Task, subtasks: readonly Subtask[]): ActualProgress {
  if (task.status === 'done') return { value: 1, source: subtasks.length ? 'subtasks' : 'manual', sampleAt: task.actualEnd };
  const sp = subtaskProgress(subtasks);
  if (sp != null) {
    const last = subtasks.reduce<number | null>((m, s) => (s.completedAt != null && (m == null || s.completedAt > m) ? s.completedAt : m), null);
    return { value: sp, source: 'subtasks', sampleAt: last };
  }
  if (task.manualProgress) return { value: task.manualProgress.value, source: 'manual', sampleAt: task.manualProgress.at };
  return { value: null, source: 'none', sampleAt: null };
}

export function canScrubProgress(task: Task, subtasks: readonly Subtask[]): boolean {
  return task.kind === 'do' && task.status !== 'done' && subtasks.length === 0;
}

export type Eta =
  | { kind: 'estimate'; at: EpochMs }
  | { kind: 'unavailable'; reason: 'noBasis' | 'notRunning' | 'tooEarly' | 'complete' | 'stalled' };

/** 実績の根拠が十分にあるときだけ予測終了時刻を返す。値を捏造しない。 */
export function estimateEnd(task: Task, subtasks: readonly Subtask[], now: EpochMs): Eta {
  if (task.kind !== 'do') return { kind: 'unavailable', reason: 'noBasis' };
  if (task.status === 'done') return { kind: 'unavailable', reason: 'complete' };
  if (task.status !== 'running') return { kind: 'unavailable', reason: 'notRunning' };
  const ap = actualProgress(task, subtasks);
  if (ap.value == null || ap.sampleAt == null) return { kind: 'unavailable', reason: 'noBasis' };
  if (ap.value <= 0) return { kind: 'unavailable', reason: 'noBasis' };
  if (ap.value >= 1) return { kind: 'unavailable', reason: 'complete' };
  const workedAtSample = ap.source === 'manual' && task.manualProgress ? task.manualProgress.workedMsAtSample : workedMs(task, ap.sampleAt);
  if (workedAtSample < 2 * MINUTE) return { kind: 'unavailable', reason: 'tooEarly' };
  const totalNeeded = workedAtSample / ap.value;
  const remaining = totalNeeded - workedMs(task, now);
  if (remaining <= 0) return { kind: 'unavailable', reason: 'stalled' };
  return { kind: 'estimate', at: now + remaining };
}

export const ETA_REASON_JA: Record<Exclude<Eta, { kind: 'estimate' }>['reason'], string> = {
  noBasis: '未算出',
  notRunning: '未算出',
  tooEarly: '算出中',
  complete: '—',
  stalled: '算出中',
};

export interface DelayInfo {
  delayed: boolean;
  /** 予定終了を過ぎた分数 */
  overMinutes: number;
}

/** 未完了で予定終了時刻を過ぎていれば遅延。確認タスクは対象外。 */
export function delayInfo(task: Task, now: EpochMs): DelayInfo {
  if (task.kind !== 'do' || task.status === 'done' || task.plannedEnd == null || now <= task.plannedEnd) {
    return { delayed: false, overMinutes: 0 };
  }
  return { delayed: true, overMinutes: Math.max(1, Math.floor((now - task.plannedEnd) / MINUTE)) };
}

export type TimeLabel =
  | { kind: 'plannedStart'; at: EpochMs }
  | { kind: 'plannedEnd'; at: EpochMs }
  | { kind: 'eta'; at: EpochMs }
  | { kind: 'actualEnd'; at: EpochMs }
  | { kind: 'check'; at: EpochMs }
  | { kind: 'none' };

/** タスク行の右端に出す時刻：未開始＝予定開始、開始後＝終了（予測または予定）、完了＝実績終了 */
export function rowTimeLabel(task: Task, subtasks: readonly Subtask[], now: EpochMs): TimeLabel {
  if (task.kind === 'check') return task.checkAt != null ? { kind: 'check', at: task.checkAt } : { kind: 'none' };
  if (task.status === 'done') return task.actualEnd != null ? { kind: 'actualEnd', at: task.actualEnd } : { kind: 'none' };
  if (task.status === 'notStarted') return task.plannedStart != null ? { kind: 'plannedStart', at: task.plannedStart } : { kind: 'none' };
  const eta = estimateEnd(task, subtasks, now);
  if (eta.kind === 'estimate') return { kind: 'eta', at: eta.at };
  return task.plannedEnd != null ? { kind: 'plannedEnd', at: task.plannedEnd } : { kind: 'none' };
}
