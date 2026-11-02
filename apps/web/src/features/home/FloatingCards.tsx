import { useRef } from 'react';
import { idealProgress, workedMs, type Subtask, type Task } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { progressOf } from '../../app/progress';
import { Ring } from '../../ui/Ring';
import { openContextMenu } from '../../ui/ContextMenu';
import { useLongPress } from '../../ui/gestures';
import { repo } from '../../data/repo';

/** 円だけのコンパクト表示の高さ（円36px＋操作領域44px＋上下の余白） */
export const CARDS_H = 56;

/** 表示順（Q15）：実行中 → 一時停止中 → 次に着手するタスク → さらに次 */
export function islandOrder(tasks: Task[], now: number): Task[] {
  const running = tasks.filter((t) => t.kind === 'do' && t.status === 'running');
  const paused = tasks.filter((t) => t.kind === 'do' && t.status === 'paused');
  const upcoming = tasks
    .filter((t) => t.kind === 'do' && t.status === 'notStarted' && t.plannedStart != null && (t.plannedEnd ?? t.plannedStart) > now)
    .sort((a, b) => (a.plannedStart ?? 0) - (b.plannedStart ?? 0));
  return [...running, ...paused, ...upcoming].slice(0, 8);
}

const elapsed = (ms: number) => { const m = Math.floor(ms / 60_000); return m >= 60 ? `${Math.floor(m / 60)}時間${m % 60}分` : `${m}分`; };

/**
 * タスクのコンパクト表示（C01）：進捗リング付きの円だけを横に並べる。文字・背景のピル・枠・線は描かない。
 * 名前・状態・実績／理想の別・％は読み上げ名に含める。タップで情報・実行パネル、長押しで操作。
 */
export function FloatingCards({ tasks, subtasksByTask, now }: { tasks: Task[]; subtasksByTask: Map<string, Subtask[]>; now: number }) {
  const list = islandOrder(tasks, now);
  if (!list.length) return null;
  return (
    <div className="island-circles" data-testid="floating-cards" role="list" aria-label="実行中・次のタスク">
      {list.map((t) => <IslandCircle key={t.id} task={t} subtasks={subtasksByTask.get(t.id) ?? []} now={now} />)}
    </div>
  );
}

function IslandCircle({ task: t, subtasks, now }: { task: Task; subtasks: Subtask[]; now: number }) {
  const { openSheet } = useUIActions();
  const { studioTypes } = useData();
  const ref = useRef<HTMLButtonElement>(null);
  const pr = progressOf(t, subtasks, studioTypes, now);
  const ideal = idealProgress(t, now);
  const running = t.status === 'running';
  const state = running ? `実行中 ${elapsed(workedMs(t, now))}` : t.status === 'paused' ? '一時停止中' : '次のタスク';
  const pct = pr.value != null ? `実績${Math.round(pr.value * 100)}%` : ideal != null ? `実績未入力、理想${Math.round(ideal * 100)}%` : '実績未入力';
  const lp = useLongPress({
    onLongPress: () => ref.current && openContextMenu({
      anchor: ref.current,
      label: t.title,
      preview: <div className="ctx-card"><strong>{t.title}</strong><span>{state}</span></div>,
      items: [
        ...(t.status === 'notStarted' ? [{ label: '開始', icon: 'play' as const, onSelect: () => void repo.taskAction(t.id, 'start') }] : []),
        ...(running ? [{ label: '停止', icon: 'pause' as const, onSelect: () => void repo.taskAction(t.id, 'pause') }, { label: '完了', icon: 'check' as const, onSelect: () => void repo.taskAction(t.id, 'finish') }] : []),
        ...(t.status === 'paused' ? [{ label: '再開', icon: 'play' as const, onSelect: () => void repo.taskAction(t.id, 'resume') }] : []),
        { label: '編集', icon: 'pencil' as const, onSelect: () => openSheet({ kind: 'edit', mode: 'task', id: t.id }) },
      ],
    }),
  });
  return (
    <button
      ref={ref}
      type="button"
      role="listitem"
      className={`icircle ${running ? 'running' : ''}`}
      onClick={() => { if (!lp.consumedClick()) openSheet({ kind: 'run', id: t.id }); }}
      onPointerDown={lp.onPointerDown} onPointerMove={lp.onPointerMove} onPointerUp={lp.onPointerUp} onPointerCancel={lp.onPointerCancel} onContextMenu={lp.onContextMenu}
      aria-label={`${t.title}、${state}、${pct}`}
      data-testid={running ? 'fcard-running' : 'fcard-next'}
    >
      <Ring value={pr.value} ideal={ideal} size={36} icon={t.icon} kind="do" running={running} done={t.status === 'done'} />
    </button>
  );
}
