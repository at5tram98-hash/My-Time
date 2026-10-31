import { actualProgress, formatHm, idealProgress, runningAndNext, type Subtask, type Task } from '@my-time/domain';
import { useUI } from '../../app/ui';

export const CARDS_H = 64;

/**
 * カレンダー拡張時に上段タスク一覧が変形した浮遊カード。
 * 実行中タスク：緑の充填（実績があれば実績、なければ理想）。次のタスク：横長カード。
 */
export function FloatingCards({ tasks, subtasksByTask, now }: { tasks: Task[]; subtasksByTask: Map<string, Subtask[]>; now: number }) {
  const { openSheet } = useUI();
  const { running, next } = runningAndNext(tasks, now);
  return (
    <div className="float-cards" data-testid="floating-cards">
      {running.map((t) => {
        const ap = actualProgress(t, subtasksByTask.get(t.id) ?? []);
        const p = ap.value ?? idealProgress(t, now) ?? 0;
        return (
          <button key={t.id} type="button" className="fcard running" onClick={() => openSheet({ kind: 'task', id: t.id })} aria-label={`実行中 ${t.title} ${Math.round(p * 100)}%（${ap.value != null ? '実績' : '理想'}）`} data-testid="fcard-running">
            <span className="fcard-fill" style={{ width: `${Math.round(p * 100)}%` }} />
            <span className="fcard-icon">{t.icon}</span>
            <span className="fcard-title">{t.title}</span>
            <span className="fcard-pct">{Math.round(p * 100)}%</span>
          </button>
        );
      })}
      {next && (
        <button type="button" className="fcard next" onClick={() => openSheet({ kind: 'task', id: next.id })} data-testid="fcard-next">
          <span className="fcard-icon">{next.icon}</span>
          <span className="fcard-text">
            <span className="fcard-kicker">次のタスク</span>
            <span className="fcard-title">{next.title}</span>
          </span>
          <span className="fcard-time">{next.plannedStart != null && next.plannedStart > now ? `${formatHm(next.plannedStart)} 開始` : next.plannedEnd != null ? `${formatHm(next.plannedEnd)} 終了` : ''}</span>
        </button>
      )}
    </div>
  );
}
