import { useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  actualProgress, availableActions, canAddSubtask, delayInfo, ETA_REASON_JA, estimateEnd, formatDuration, formatHm, idealProgress,
  workedMs, type TaskAction,
} from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Icon, type IconName } from '../../components/Icon';
import { TaskIcon } from '../../components/TaskIcon';
import { useData, useSubtasks } from '../../app/data';
import { useUI } from '../../app/ui';
import { useNow } from '../../app/useNow';
import { formatFull, formatRange } from '../../app/format';
import { db } from '../../data/db';
import { repo } from '../../data/repo';

const ACTION_UI: Record<TaskAction, { label: string; icon: IconName; tone: 'primary' | 'plain' | 'green' }> = {
  start: { label: '開始', icon: 'play', tone: 'primary' },
  pause: { label: '一時停止', icon: 'pause', tone: 'plain' },
  resume: { label: '再開', icon: 'play', tone: 'primary' },
  finish: { label: '終了', icon: 'check', tone: 'green' },
  undoFinish: { label: '完了を取り消す', icon: 'undo', tone: 'plain' },
  undoStart: { label: '開始を取り消す', icon: 'undo', tone: 'plain' },
};

const LOG_JA: Record<string, string> = {
  create: '作成', update: '編集', start: '開始', pause: '一時停止', resume: '再開', finish: '終了', undoFinish: '完了を取り消し',
  undoStart: '開始を取り消し', progress: '実績を入力', check: 'チェック', uncheck: 'チェックを解除', convert: '種類を変更', move: '時間を移動',
  complete: 'サブタスク完了', uncomplete: 'サブタスク完了を取り消し', delete: '削除',
};

export function TaskDetailSheet({ id, depth }: { id: string; depth: number }) {
  const { tasks, calendarById } = useData();
  const { closeSheet, openSheet, confirm, showToast } = useUI();
  const now = useNow(5_000);
  const task = tasks.find((t) => t.id === id);
  const subtasks = useSubtasks(id);
  const [newSub, setNewSub] = useState('');
  const logs = useLiveQuery(() => db.operationLog.where('entityId').equals(id).reverse().sortBy('seq'), [id]);

  if (!task) {
    return (
      <Sheet onClose={closeSheet} depth={depth} title="タスク" left={<button className="bar-btn" onClick={closeSheet}>閉じる</button>}>
        <p className="empty-note">このタスクは削除されました。</p>
      </Sheet>
    );
  }

  const ideal = idealProgress(task, now);
  const ap = actualProgress(task, subtasks);
  const eta = estimateEnd(task, subtasks, now);
  const delay = delayInfo(task, now);
  const cal = task.calendarId ? calendarById.get(task.calendarId) : undefined;

  const run = async (a: TaskAction) => {
    try {
      await repo.taskAction(task.id, a);
      if (a === 'undoFinish' || a === 'undoStart') showToast('取り消しました');
    } catch (e) {
      showToast(e instanceof Error ? e.message : '操作できませんでした');
    }
  };

  const remove = async () => {
    const ok = await confirm({ title: 'タスクを削除しますか？', message: `「${task.title}」とサブタスク、実績が削除されます。`, confirmLabel: '削除', destructive: true });
    if (!ok) return;
    await repo.deleteTask(task.id);
    closeSheet();
    showToast('削除しました');
  };

  const addSub = async () => {
    const title = newSub.trim();
    if (!title) return;
    try {
      await repo.addSubtask(task.id, title);
      setNewSub('');
    } catch (e) {
      showToast(e instanceof Error ? e.message : '追加できませんでした');
    }
  };

  return (
    <Sheet
      onClose={closeSheet}
      depth={depth}
      labelledBy="task-detail-title"
      left={<button type="button" className="bar-btn" onClick={closeSheet}>閉じる</button>}
      right={<button type="button" className="bar-btn bold" onClick={() => openSheet({ kind: 'editTask', taskId: task.id })}>編集</button>}
    >
      <div className="detail-hero">
        <TaskIcon task={task} now={now} size={56} />
        <h2 id="task-detail-title" className="detail-title">{task.title}</h2>
        <div className="detail-meta">
          {task.kind === 'check' ? '確認タスク' : '実施タスク'}
          {task.category ? ` · ${task.category}` : ''}
          {task.autoReserved && <span className="ar-badge">AR</span>}
        </div>
      </div>

      {task.kind === 'do' && (
        <div className="action-row" data-testid="task-actions">
          {availableActions(task).map((a) => (
            <button key={a} type="button" className={`pill-btn ${ACTION_UI[a].tone}`} onClick={() => void run(a)}>
              <Icon name={ACTION_UI[a].icon} size={18} strokeWidth={2.2} />
              {ACTION_UI[a].label}
            </button>
          ))}
        </div>
      )}
      {task.kind === 'check' && (
        <div className="action-row">
          <button type="button" className={`pill-btn ${task.checked ? 'plain' : 'green'}`} onClick={() => void repo.toggleCheck(task.id)}>
            <Icon name={task.checked ? 'undo' : 'check'} size={18} strokeWidth={2.2} />
            {task.checked ? 'チェックを外す' : '確認済みにする'}
          </button>
        </div>
      )}

      <div className="group">
        <div className="group-body">
          {task.kind === 'do' ? (
            <>
              <div className="row"><span className="row-label">予定</span><span className="row-value">{task.plannedStart != null && task.plannedEnd != null ? formatRange(task.plannedStart, task.plannedEnd) : '未設定'}</span></div>
              <div className="row"><span className="row-label">実績開始</span><span className="row-value">{task.actualStart != null ? formatFull(task.actualStart) : '—'}</span></div>
              <div className="row"><span className="row-label">実績終了</span><span className="row-value">{task.actualEnd != null ? formatFull(task.actualEnd) : '—'}</span></div>
              <div className="row"><span className="row-label">作業時間</span><span className="row-value">{formatDuration(workedMs(task, now))}</span></div>
              {task.status !== 'done' && (
                <div className="row">
                  <span className="row-label">予測終了</span>
                  <span className={`row-value ${eta.kind === 'estimate' ? 'tint' : ''}`} data-testid="eta-value">{eta.kind === 'estimate' ? formatHm(eta.at) : ETA_REASON_JA[eta.reason]}</span>
                </div>
              )}
              {delay.delayed && <div className="row"><span className="row-label">遅延</span><span className="row-value late">予定終了から {delay.overMinutes}分</span></div>}
            </>
          ) : (
            <>
              <div className="row"><span className="row-label">確認日時</span><span className="row-value">{task.checkAt != null ? formatFull(task.checkAt) : '未設定'}</span></div>
              {task.checkedAt != null && <div className="row"><span className="row-label">確認済み</span><span className="row-value">{formatFull(task.checkedAt)}</span></div>}
            </>
          )}
        </div>
        {task.kind === 'do' && <div className="group-footer">予測終了は実績（手動入力またはサブタスク完了）がある実行中のタスクだけ計算します。</div>}
      </div>

      <div className="group">
        <div className="group-body">
          <div className="row"><span className="row-label">カレンダー</span><span className="row-value"><span className="cal-dot" style={{ background: cal?.color ?? 'var(--gray)' }} />{cal?.name ?? 'なし'}</span></div>
          <div className="row"><span className="row-label">通知</span><span className="row-value muted">準備中（Phase 2）</span></div>
        </div>
      </div>

      {task.kind === 'do' && (
        <div className="group">
          <div className="group-header">進捗</div>
          <div className="group-body padded">
            <ProgressLine label="理想" value={ideal} tone="ideal" />
            <ProgressLine label={ap.source === 'subtasks' ? '実績（サブタスク）' : '実績'} value={ap.value} tone="actual" />
          </div>
          <div className="group-footer">{subtasks.length > 0 ? 'サブタスクがあるため、実績は完了数から自動計算されます。' : '一覧のタスクを長押しして左右にスライドすると実績を入力できます。'}</div>
        </div>
      )}

      {task.kind === 'do' && (
        <div className="group" data-testid="subtasks">
          <div className="group-header">サブタスク</div>
          <div className="group-body">
            {subtasks.map((s) => (
              <div className="row sub-row" key={s.id}>
                <button type="button" role="checkbox" aria-checked={s.done} aria-label={`${s.title}を完了`} className={`check-circle small ${s.done ? 'on' : ''}`} onClick={() => void repo.toggleSubtask(s.id)}>
                  {s.done && <Icon name="check" size={13} strokeWidth={3} />}
                </button>
                <span className={`row-label ${s.done ? 'struck' : ''}`}>{s.title}</span>
                <span className="row-value small muted">{s.completedAt != null ? formatHm(s.completedAt) : ''}</span>
                <button type="button" className="icon-btn subtle" aria-label={`${s.title}を削除`} onClick={() => void repo.deleteSubtask(s.id)}>
                  <Icon name="close" size={16} />
                </button>
              </div>
            ))}
            {canAddSubtask(task) ? (
              <form
                className="row"
                onSubmit={(e) => {
                  e.preventDefault();
                  void addSub();
                }}
              >
                <Icon name="plus" size={18} className="tint" />
                <input className="row-input" value={newSub} onChange={(e) => setNewSub(e.target.value)} placeholder="サブタスクを追加" aria-label="サブタスク名" enterKeyHint="done" />
              </form>
            ) : (
              <div className="row"><span className="row-label muted">予定に含まれるタスクにはサブタスクを追加できません</span></div>
            )}
          </div>
        </div>
      )}

      <div className="group">
        <div className="group-header">実績ログ</div>
        <div className="group-body">
          {task.intervals.map((iv, i) => (
            <div className="row" key={`iv-${i}`}>
              <span className="row-label">作業 {i + 1}</span>
              <span className="row-value">{formatHm(iv.start)}〜{iv.end != null ? formatHm(iv.end) : '計測中'}</span>
            </div>
          ))}
          {(logs ?? []).slice(0, 12).map((l) => (
            <div className="row log-row" key={l.seq ?? l.id}>
              <span className="row-label">{LOG_JA[l.action] ?? l.action}{l.action === 'progress' && typeof l.detail?.value === 'number' ? ` ${Math.round((l.detail.value as number) * 100)}%` : ''}</span>
              <span className="row-value small muted">{formatFull(l.at)}</span>
            </div>
          ))}
          {task.intervals.length === 0 && (logs ?? []).length === 0 && <div className="row"><span className="row-label muted">記録はまだありません</span></div>}
        </div>
      </div>

      {task.notes && (
        <div className="group">
          <div className="group-header">メモ</div>
          <div className="group-body padded notes">{task.notes}</div>
        </div>
      )}

      <div className="group">
        <div className="group-body">
          <button type="button" className="row row-button destructive center" onClick={() => void remove()} data-testid="delete-task">
            タスクを削除
          </button>
        </div>
      </div>
    </Sheet>
  );
}

function ProgressLine({ label, value, tone }: { label: string; value: number | null; tone: 'ideal' | 'actual' }) {
  return (
    <div className="pline">
      <div className="pline-head">
        <span>{label}</span>
        <span className="pline-val">{value == null ? '未入力' : `${Math.round(value * 100)}%`}</span>
      </div>
      <div className="pline-track">
        <div className={`pline-fill ${tone}`} style={{ width: `${Math.round((value ?? 0) * 100)}%` }} />
      </div>
    </div>
  );
}
