import { taskAnchor, type Task } from '@my-time/domain';

/** ホームだけの優先順。実行中、停止中、次の予定、過ぎた未着手、完了。元データは変更しない。 */
export function orderHomeTasks(tasks: readonly Task[], now: number): Task[] {
  const rank = (t: Task) => t.status === 'done' || t.checked ? 4 : t.status === 'running' ? 0 : t.status === 'paused' ? 1 : (taskAnchor(t) ?? now) >= now ? 2 : 3;
  return [...tasks].sort((a, b) => rank(a) - rank(b) || (taskAnchor(a) ?? 0) - (taskAnchor(b) ?? 0) || a.createdAt - b.createdAt || a.id.localeCompare(b.id));
}
