import { delayInfo, idealProgress, type Task } from '@my-time/domain';
import { TaskBadge } from './Identity';

/**
 * 一覧・ホームのタスクアイコン（C04・D3）。共通の識別バッジ（円・実行は赤／確認は青）に、
 * 外周の実績の円弧と、理想進捗の目盛りを重ねる。遅延は注意の記号、完了はチェック。
 */
export function TaskIcon({ task, now, size = 40, progress }: { task: Task; now: number; size?: number; progress?: number | null }) {
  const ideal = task.kind === 'do' && task.status !== 'done' ? idealProgress(task, now) ?? 0 : 0;
  const delayed = delayInfo(task, now).delayed;
  const done = task.kind === 'check' ? !!task.checked : task.status === 'done';
  return (
    <span className={`task-icon ${task.status === 'running' ? 'running' : ''}`} data-ideal={Math.round(ideal * 100)}>
      <TaskBadge
        icon={task.icon}
        kind={task.kind === 'check' ? 'check' : 'do'}
        size={size}
        progress={task.kind === 'do' ? progress ?? null : undefined}
        ideal={task.kind === 'do' ? ideal : undefined}
        done={done}
        delayed={delayed && !done}
        running={task.status === 'running'}
        {...(delayed && !done ? { label: '遅延' } : {})}
      />
    </span>
  );
}
