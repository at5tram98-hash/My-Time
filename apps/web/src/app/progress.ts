import { resolveProgress, workedMs, type ResolvedProgress, type StudioType, type Subtask, type Task } from '@my-time/domain';

/** 画面共通の進捗の根拠（D3・F2）。リング・説明・実績欄・進捗パネルはすべてこれを使う */
export function progressOf(task: Task, subtasks: readonly Subtask[], studioTypes: readonly StudioType[], now: number): ResolvedProgress {
  const st = task.extra?.studio ? studioTypes.find((t) => t.id === task.extra!.studio!.typeId) : undefined;
  return resolveProgress(task, subtasks, st ?? null, workedMs(task, now) / 60_000);
}
