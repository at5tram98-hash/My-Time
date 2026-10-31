import type { EpochMs, Subtask, Task, TaskAction, TaskKind, TaskStatus } from './types';
import { workedMs } from './progress';

export interface TaskTransition {
  task: Task;
  log: { action: TaskAction | 'progress' | 'check' | 'uncheck' | 'convert'; from: TaskStatus; to: TaskStatus; at: EpochMs; detail?: Record<string, unknown> };
}

export class InvalidTransitionError extends Error {
  constructor(action: string, status: TaskStatus) {
    super(`操作「${action}」は状態「${status}」では実行できません`);
    this.name = 'InvalidTransitionError';
  }
}

/** UIで出す操作一覧（状態から純粋に決まる） */
export function availableActions(task: Task): TaskAction[] {
  if (task.kind !== 'do') return [];
  switch (task.status) {
    case 'notStarted':
      return ['start'];
    case 'running':
      return task.intervals.length === 1 && !task.pausedEver ? ['pause', 'finish', 'undoStart'] : ['pause', 'finish'];
    case 'paused':
      return ['resume', 'finish'];
    case 'done':
      return ['undoFinish'];
  }
}

function closeOpen(task: Task, at: EpochMs) {
  return task.intervals.map((iv) => (iv.end == null ? { ...iv, end: Math.max(iv.start, at) } : iv));
}

/**
 * 実施タスクの状態機械。未開始→実行中↔一時停止→完了、および取り消し。
 * - 完了の取り消しは「一時停止」に戻す（取り消しまでの時間を作業時間として捏造しない）。
 * - 開始の取り消しは一時停止前の最初の区間のみ可能で、実績区間を消し未開始に戻す。
 * 取り消し自体も log として返し、操作ログに残す。
 */
export function applyTaskAction(task: Task, action: TaskAction, at: EpochMs): TaskTransition {
  if (task.kind !== 'do') throw new InvalidTransitionError(action, task.status);
  if (!availableActions(task).includes(action)) throw new InvalidTransitionError(action, task.status);
  const from = task.status;
  let next: Task;
  switch (action) {
    case 'start':
      next = { ...task, status: 'running', intervals: [...task.intervals, { start: at, end: null }], actualStart: task.actualStart ?? at, actualEnd: null };
      break;
    case 'pause':
      next = { ...task, status: 'paused', intervals: closeOpen(task, at), pausedEver: true };
      break;
    case 'resume':
      next = { ...task, status: 'running', intervals: [...task.intervals, { start: at, end: null }] };
      break;
    case 'finish':
      next = { ...task, status: 'done', intervals: closeOpen(task, at), actualEnd: at };
      break;
    case 'undoFinish':
      next = { ...task, status: 'paused', actualEnd: null };
      break;
    case 'undoStart':
      next = { ...task, status: 'notStarted', intervals: [], actualStart: null, actualEnd: null, manualProgress: null };
      break;
  }
  next.updatedAt = at;
  return { task: next, log: { action, from, to: next.status, at } };
}

/** 長押しスライドで確定した実績進捗を記録する。value>=1 の完了はUIで確認後 finish を別に呼ぶ。 */
export function recordManualProgress(task: Task, subtasks: readonly Subtask[], value: number, at: EpochMs): TaskTransition {
  if (task.kind !== 'do' || task.status === 'done' || subtasks.length > 0) {
    throw new InvalidTransitionError('progress', task.status);
  }
  const v = Math.round(Math.min(1, Math.max(0, value)) * 100) / 100;
  const next: Task = { ...task, manualProgress: { value: v, at, workedMsAtSample: workedMs(task, at) }, updatedAt: at };
  return { task: next, log: { action: 'progress', from: task.status, to: task.status, at, detail: { value: v, previous: task.manualProgress?.value ?? null } } };
}

export function toggleCheck(task: Task, at: EpochMs): TaskTransition {
  if (task.kind !== 'check') throw new InvalidTransitionError('check', task.status);
  const checked = !task.checked;
  const next: Task = { ...task, checked, checkedAt: checked ? at : null, status: checked ? 'done' : 'notStarted', updatedAt: at };
  return { task: next, log: { action: checked ? 'check' : 'uncheck', from: task.status, to: next.status, at } };
}

export interface ConversionPreview {
  allowed: boolean;
  warnings: string[];
}

/** 実施⇔確認の変換前プレビュー。実績履歴は消さない（保持したまま種別だけ変える）。 */
export function previewConversion(task: Task, to: TaskKind): ConversionPreview {
  if (task.kind === to) return { allowed: false, warnings: [] };
  const warnings: string[] = [];
  if (to === 'check') {
    if (task.status === 'running' || task.status === 'paused') warnings.push('実行中/一時停止中の計測を終了して確認タスクにします。記録済みの実績は保持されます。');
    if (task.intervals.length > 0) warnings.push('実績時間の記録は残りますが、確認タスクでは表示されません。');
  } else if (task.checked) {
    warnings.push('チェック済みの状態は解除され、未開始の実施タスクになります。');
  }
  return { allowed: true, warnings };
}

export function convertKind(task: Task, to: TaskKind, at: EpochMs): TaskTransition {
  if (task.kind === to) throw new InvalidTransitionError('convert', task.status);
  let next: Task;
  if (to === 'check') {
    next = { ...task, kind: 'check', intervals: closeOpen(task, at), status: 'notStarted', checked: false, checkedAt: null, checkAt: task.checkAt ?? task.plannedStart };
  } else {
    next = { ...task, kind: 'do', status: task.intervals.length > 0 ? 'paused' : 'notStarted', checked: false, checkedAt: null };
  }
  next.updatedAt = at;
  return { task: next, log: { action: 'convert', from: task.status, to: next.status, at, detail: { fromKind: task.kind, toKind: to } } };
}

/** 予定に内包されるタスクはサブタスクを持てない（排他制約） */
export function canAddSubtask(task: Pick<Task, 'eventId' | 'kind'>): boolean {
  return task.eventId == null && task.kind === 'do';
}

export function toggleSubtask(sub: Subtask, at: EpochMs): Subtask {
  return { ...sub, done: !sub.done, completedAt: sub.done ? null : at, updatedAt: at };
}
