import type { CalEvent, EpochMs, Subtask, Task } from './types';
import { addDays, overlapsDay } from './time';
import { delayInfo, estimateEnd } from './progress';

/** 時刻の基準（実施＝予定開始、確認＝確認日時） */
export function taskAnchor(task: Task): EpochMs | null {
  return task.kind === 'check' ? task.checkAt : task.plannedStart;
}

/** ホーム上段：指定日（左端の表示日）に時刻指定されたタスクのみ、時刻順 */
export function tasksForDay(tasks: readonly Task[], dayStart: EpochMs): Task[] {
  const dayEnd = addDays(dayStart, 1);
  return tasks
    .filter((t) => {
      if (t.kind === 'check') return t.checkAt != null && t.checkAt >= dayStart && t.checkAt < dayEnd;
      if (t.plannedStart == null) return false;
      const end = t.plannedEnd ?? t.plannedStart;
      return overlapsDay(t.plannedStart, end, dayStart);
    })
    .sort((a, b) => (taskAnchor(a) ?? 0) - (taskAnchor(b) ?? 0) || a.createdAt - b.createdAt);
}

export function eventsForDay(events: readonly CalEvent[], dayStart: EpochMs): CalEvent[] {
  return events.filter((e) => overlapsDay(e.start, e.end, dayStart)).sort((a, b) => a.start - b.start);
}

/** 未設定：日時が入っていないタスク */
export function isUnscheduled(task: Task): boolean {
  return task.kind === 'do' ? task.plannedStart == null : task.checkAt == null;
}

export interface TaskBlock {
  id: string;
  taskId: string;
  /** 描画上の開始・終了。遅延中は終了を現在時刻まで延長する（元データは変更しない）。 */
  start: EpochMs;
  end: EpochMs;
  plannedEnd: EpochMs;
  delayed: boolean;
  /** 予測終了（青い点線）。根拠がなければ null */
  eta: EpochMs | null;
}

/** タイムラインに描くタスクブロック（実施タスクで予定時刻があるもの） */
export function taskBlock(task: Task, subtasks: readonly Subtask[], now: EpochMs): TaskBlock | null {
  if (task.kind !== 'do' || task.plannedStart == null || task.plannedEnd == null) return null;
  const d = delayInfo(task, now);
  const eta = estimateEnd(task, subtasks, now);
  const end = d.delayed ? Math.max(task.plannedEnd, now) : task.plannedEnd;
  return {
    id: `task:${task.id}`,
    taskId: task.id,
    start: task.plannedStart,
    end,
    plannedEnd: task.plannedEnd,
    delayed: d.delayed,
    eta: eta.kind === 'estimate' ? eta.at : null,
  };
}

/** 拡張ホームの浮遊カード：実行中タスクと次のタスク */
export function runningAndNext(tasks: readonly Task[], now: EpochMs): { running: Task[]; next: Task | null } {
  const running = tasks.filter((t) => t.kind === 'do' && t.status === 'running');
  const upcoming = tasks
    .filter((t) => t.kind === 'do' && t.status === 'notStarted' && t.plannedStart != null && (t.plannedEnd ?? t.plannedStart) > now)
    .sort((a, b) => (a.plannedStart ?? 0) - (b.plannedStart ?? 0));
  return { running, next: upcoming[0] ?? null };
}
