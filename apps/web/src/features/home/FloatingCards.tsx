import { useRef } from 'react';
import { actualProgress, formatHm, idealProgress, workedMs, type Subtask, type Task } from '@my-time/domain';
import { useUIActions } from '../../app/ui';
import { Ring } from '../../ui/Ring';
import { openContextMenu } from '../../ui/ContextMenu';
import { useLongPress } from '../../ui/gestures';
import { repo } from '../../data/repo';

export const CARDS_H = 64;

/** 島の表示順（Q15）：実行中 → 一時停止中 → 次に着手するタスク → さらに次 */
export function islandOrder(tasks: Task[], now: number): Task[] {
  const running = tasks.filter((t) => t.kind === 'do' && t.status === 'running');
  const paused = tasks.filter((t) => t.kind === 'do' && t.status === 'paused');
  const upcoming = tasks
    .filter((t) => t.kind === 'do' && t.status === 'notStarted' && t.plannedStart != null && (t.plannedEnd ?? t.plannedStart) > now)
    .sort((a, b) => (a.plannedStart ?? 0) - (b.plannedStart ?? 0));
  return [...running, ...paused, ...upcoming].slice(0, 3);
}

const elapsed = (ms: number) => { const m = Math.floor(ms / 60_000); return m >= 60 ? `${Math.floor(m / 60)}時間${m % 60}分` : `${m}分`; };

/**
 * ホームの島（Q12・Q15）。タスクパネルを小さくしたときの Dynamic Island 風の表示。
 * 先頭（最優先）は詳しく、後続は省略して並べる。タップで情報、長押しで開始・停止・編集。
 */
export function FloatingCards({ tasks, subtasksByTask, now }: { tasks: Task[]; subtasksByTask: Map<string, Subtask[]>; now: number }) {
  const list = islandOrder(tasks, now);
  if (!list.length) return <div className="float-cards" data-testid="floating-cards" />;
  return (
    <div className="float-cards island" data-testid="floating-cards">
      {list.map((t, i) => <IslandCard key={t.id} task={t} subtasks={subtasksByTask.get(t.id) ?? []} now={now} primary={i === 0} />)}
    </div>
  );
}

function IslandCard({ task: t, subtasks, now, primary }: { task: Task; subtasks: Subtask[]; now: number; primary: boolean }) {
  const { openSheet } = useUIActions();
  const ref = useRef<HTMLButtonElement>(null);
  const ap = actualProgress(t, subtasks);
  const p = ap.value ?? idealProgress(t, now) ?? 0;
  const running = t.status === 'running';
  const status = running ? `実行中 ${elapsed(workedMs(t, now))}` : t.status === 'paused' ? '一時停止中' : t.plannedStart != null ? `${formatHm(t.plannedStart)}〜` : '予定なし';
  const lp = useLongPress({
    onLongPress: () => ref.current && openContextMenu({
      anchor: ref.current,
      label: t.title,
      preview: <div className="ctx-card"><strong>{t.title}</strong><span>{status}</span></div>,
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
      className={`fcard ${primary ? 'primary' : 'compact'} ${running ? 'running' : 'next'}`}
      onClick={() => { if (!lp.consumedClick()) openSheet({ kind: 'info', entity: 'task', id: t.id }); }}
      onPointerDown={lp.onPointerDown} onPointerMove={lp.onPointerMove} onPointerUp={lp.onPointerUp} onPointerCancel={lp.onPointerCancel} onContextMenu={lp.onContextMenu}
      aria-label={`${running ? '実行中' : '次のタスク'} ${t.title} ${Math.round(p * 100)}%（${ap.value != null ? '実績' : '理想'}）。${status}`}
      data-testid={running ? 'fcard-running' : 'fcard-next'}
    >
      <Ring value={p} size={primary ? 40 : 30} icon={t.icon} />
      <span className="fcard-text">
        {primary && <span className="fcard-kicker">{running ? '実行中' : t.status === 'paused' ? '一時停止中' : '次のタスク'}</span>}
        <span className="fcard-title">{t.title}</span>
        {primary && <span className="fcard-sub">{status}</span>}
      </span>
      {primary && <span className="fcard-pct">{Math.round(p * 100)}%</span>}
    </button>
  );
}
