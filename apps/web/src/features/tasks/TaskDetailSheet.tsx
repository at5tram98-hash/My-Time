import { useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  actualProgress, canAddSubtask, delayInfo, ETA_REASON_JA, subtaskLabel, estimateEnd, formatDuration, formatHm, idealProgress,
  workedMs, type Task, type TaskAction,
} from '@my-time/domain';
import { formatOverMinutes } from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Icon, type IconName } from '../../components/Icon';
import { TaskIcon } from '../../components/TaskIcon';
import { useData, useSubtasks } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { useNow } from '../../app/useNow';
import { formatFull, formatRange } from '../../app/format';
import { db } from '../../data/db';
import { repo } from '../../data/repo';
import { Ring } from '../../ui/Ring';
import { Popup } from '../../ui/Popup';
import { deleteWithUndo } from '../../ui/undo';
import { StudioValueView } from '../studio/StudioFieldsForm';
import { studioProgress } from '@my-time/domain';


const LOG_JA: Record<string, string> = {
  create: '作成', update: '編集', start: '開始', pause: '一時停止', resume: '再開', finish: '終了', undoFinish: '完了を取り消し',
  undoStart: '開始を取り消し', progress: '実績を入力', check: 'チェック', uncheck: 'チェックを解除', convert: '種類を変更', move: '時間を移動',
  complete: 'サブタスク完了', uncomplete: 'サブタスク完了を取り消し', delete: '削除',
};

export function TaskDetailSheet({ id, depth }: { id: string; depth: number }) {
  const { tasks, events, calendarById, studioTypes } = useData();
  const [progressOpen, setProgressOpen] = useState(false);
  const [manual, setManual] = useState(0);
  const { closeSheet, openSheet, confirm, showToast } = useUIActions();
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
  const source = task.sourceEventId ? events.find((e) => e.id === task.sourceEventId) : undefined;

  const run = async (a: TaskAction) => {
    try {
      await repo.taskAction(task.id, a);
      if (a === 'undoFinish' || a === 'undoStart') showToast('取り消しました');
    } catch (e) {
      showToast(e instanceof Error ? e.message : '操作できませんでした');
    }
  };

  // 削除は数秒間取り消せる（Q41・Q101）
  const remove = async () => {
    const ok = await confirm({ title: 'タスクを削除しますか？', message: `「${task.title}」とサブタスク、実績が削除されます。直後なら取り消せます。`, confirmLabel: '削除', destructive: true });
    if (!ok) return;
    closeSheet();
    deleteWithUndo(`task:${task.id}`, `「${task.title}」`, () => repo.deleteTask(task.id));
  };
  // 完了は控えめに確定し、直後に取り消せる（Q92）
  const finish = async () => {
    await run('finish');
    showToast('完了しました。取り消すには「完了を取り消す」');
  };
  const st = task.extra?.studio ? studioTypes.find((t) => t.id === task.extra!.studio!.typeId) : undefined;
  const worked = workedMs(task, now);
  const sp = st ? studioProgress(st, task.extra!.studio!.values, worked / 60_000) : null;
  const ringValue = sp?.value ?? ap.value ?? (task.status === 'done' ? 1 : ideal ?? 0);

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
      right={<button type="button" className="gbtn glass glass-i tint" aria-label="編集" onClick={() => openSheet({ kind: 'edit', mode: 'task', id: task.id })} data-testid="info-edit"><Icon name="pencil" size={18} /></button>}
      detent="medium"
      detents={['medium', 'large']}
      testId="task-info"
    >
      {/* 実行パネル（Q35・Q92）：名前と進捗リング → 見積／経過 → 大きな主ボタン */}
      {task.kind === 'do' && (
        <div className="run-panel" data-testid="run-panel">
          <button type="button" className="run-ring" onClick={() => { setManual(Math.round((ap.value ?? 0) * 100)); setProgressOpen(true); }} aria-label="進捗の詳細" data-testid="run-ring">
            <Ring value={ringValue} size={64} icon={task.icon} done={task.status === 'done'} />
          </button>
          <div className="run-time" aria-live="polite" data-testid="run-time">
            {task.status === 'running' || task.status === 'paused' ? <><span className="run-elapsed">{formatElapsed(worked)}</span><span className="muted small">{task.status === 'paused' ? '一時停止中' : '実行中'}</span></>
              : task.status === 'done' ? <><span className="run-elapsed">{formatElapsed(worked)}</span><span className="muted small">完了</span></>
              : <><span className="run-elapsed">{task.estimateMinutes != null ? `${task.estimateMinutes}分` : '—'}</span><span className="muted small">{task.estimateMinutes != null ? '見積時間' : '見積なし'}</span></>}
            {sp?.label && <span className="muted small">{sp.label}</span>}
          </div>
          <div className="run-actions">
            {task.status === 'notStarted' && <button type="button" className="gbtn-primary big glass-i" onClick={() => void run('start')} data-testid="run-start"><Icon name="play" size={20} />開始</button>}
            {task.status === 'running' && (<><button type="button" className="gbtn-primary big glass-i neutral" onClick={() => void run('pause')} data-testid="run-pause"><Icon name="pause" size={20} />停止</button><button type="button" className="gbtn-primary big green glass-i" onClick={() => void finish()} data-testid="run-finish"><Icon name="check" size={20} />完了</button></>)}
            {task.status === 'paused' && (<><button type="button" className="gbtn-primary big glass-i" onClick={() => void run('resume')} data-testid="run-resume"><Icon name="play" size={20} />再開</button><button type="button" className="gbtn-primary big green glass-i" onClick={() => void finish()} data-testid="run-finish"><Icon name="check" size={20} />完了</button></>)}
            {task.status === 'done' && <button type="button" className="gbtn-primary big glass-i neutral" onClick={() => void run('undoFinish')} data-testid="run-undo"><Icon name="undo" size={20} />完了を取り消す</button>}
          </div>
          {task.status !== 'done' && (
            <button type="button" className="ar-btn glass glass-i" onClick={() => openSheet({ kind: 'autoReserve', taskId: task.id })} data-testid="run-ar">
              <Icon name="clock" size={16} />
              {task.autoStartAt != null || task.autoEndAt != null ? `予約 ${task.autoStartAt != null ? formatHm(task.autoStartAt) + ' 開始' : ''}${task.autoEndAt != null ? ' ' + formatHm(task.autoEndAt) + ' 終了' : ''}` : 'AR予約'}
            </button>
          )}
        </div>
      )}
      <Popup open={progressOpen} title="進捗" onClose={() => setProgressOpen(false)} onDone={subtasks.length || st ? undefined : () => { setProgressOpen(false); void repo.recordProgress(task.id, manual / 100); }} testId="progress-popup">
        {subtasks.length > 0 ? <p className="note-text">サブタスクの完了数から自動で計算します（{subtasks.filter((x) => x.done).length}/{subtasks.length}）。</p>
          : st ? <p className="note-text">「{st.name}」の項目から計算します。値は編集画面の「{st.name}」で変更できます。{sp?.label}</p>
          : (<>
            <p className="note-text">実績の進捗を入力します（リングをなぞって変える操作はありません）。</p>
            <div className="prog-input"><input type="range" min={0} max={100} step={5} value={manual} onChange={(e) => setManual(Number(e.target.value))} aria-label="進捗（%）" data-testid="progress-range" /><span className="run-elapsed">{manual}%</span></div>
          </>)}
      </Popup>
      <div className="detail-hero">
        {task.kind === 'check' && <TaskIcon task={task} now={now} size={56} />}
        <h2 id="task-detail-title" className="detail-title">{task.title}</h2>
        <div className="detail-meta">
          {task.kind === 'check' ? '確認タスク' : st ? st.name : task.special === 'assignment' ? '課題' : task.special === 'testPrep' ? 'テスト対策' : '実行タスク'}
          {task.category ? ` · ${task.category}` : ''}
          {task.flagged && <span className="flag-mark" role="img" aria-label="フラグ付き"><Icon name="flag" size={15} strokeWidth={2.2} /></span>}
          {task.priority > 0 && <span className="prio-mark" role="img" aria-label={`優先度${['', '低', '中', '高'][task.priority]}`}>{Array.from({ length: task.priority }, (_, i) => <Icon key={i} name="exclamation" size={14} strokeWidth={2.6} />)}</span>}
          {task.autoReserved && <span className="ar-badge">AR</span>}
        </div>
        {task.tags.length > 0 && <div className="tag-line">{task.tags.map((t) => <span key={t} className="tag">#{t}</span>)}</div>}
      </div>

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
              {delay.delayed && <div className="row"><span className="row-label">遅延</span><span className="row-value late">予定終了から {formatOverMinutes(delay.overMinutes)}</span></div>}
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
          <div className="row"><span className="row-label">通知</span><span className="row-value">{task.notifyMinutesBefore == null ? 'なし' : task.notifyMinutesBefore === 0 ? '時刻ちょうど' : task.notifyMinutesBefore >= 60 ? `${task.notifyMinutesBefore / 60}時間前` : `${task.notifyMinutesBefore}分前`}</span></div>
          {task.repeat && <div className="row"><span className="row-label">繰り返し</span><span className="row-value">{{ daily: '毎日', weekly: '毎週', monthly: '毎月' }[task.repeat.freq]}（完了すると次を作成）</span></div>}
          {task.location && <div className="row"><span className="row-label">場所</span><span className="row-value">{task.location}</span></div>}
          {source && (
            <button type="button" className="row row-button" onClick={() => openSheet({ kind: 'info', entity: 'event', id: source.id })}>
              <span className="row-label">元の授業</span>
              <span className="row-value tint">{source.title}</span>
            </button>
          )}
        </div>
      </div>
      {(task.assignment || task.testPrep || task.special !== 'normal') && (
        <div className="group" data-testid="special-info">
          <div className="group-header">{task.special === 'assignment' ? '課題' : 'テスト対策'}</div>
          <div className="group-body">
            {task.assignment && (
              <>
                {task.assignment.content && <div className="row"><span className="row-label">内容</span><span className="row-value">{task.assignment.content}</span></div>}
                <div className="row"><span className="row-label">提出方法</span><span className="row-value">{task.assignment.submitMethod || '未入力'}</span></div>
                <div className="row"><span className="row-label">提出先</span><span className="row-value">{task.assignment.submitTo || '未入力'}</span></div>
                <div className="row"><span className="row-label">提出期限</span><span className="row-value">{task.assignment.deadline != null ? formatFull(task.assignment.deadline) : 'なし'}</span></div>
              </>
            )}
            {task.testPrep && (
              <>
                <div className="row"><span className="row-label">科目</span><span className="row-value">{task.testPrep.subjectName || '未入力'}</span></div>
                <div className="row"><span className="row-label">試験日時</span><span className="row-value">{task.testPrep.examAt != null ? formatFull(task.testPrep.examAt) : 'なし'}</span></div>
              </>
            )}
            <div className="row"><span className="row-label">作業時間</span><span className={`row-value ${task.estimateMinutes == null ? 'late' : ''}`}>{task.estimateMinutes != null ? `${task.estimateMinutes}分` : '未入力（未設定）'}</span></div>
          </div>
        </div>
      )}

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
          <div className="group-header">{subtaskLabel(task)}</div>
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

      {st && (
        <div className="group" data-testid="info-studio">
          <div className="group-header">{st.name}</div>
          <div className="group-body">
            {st.fields.filter((f) => f.showInInfo && !f.hidden && f.type !== 'note').map((f) => (
              <div className="row" key={f.id}><span className="row-label">{f.label}</span><span className="row-value"><StudioValueView f={f} value={task.extra!.studio!.values[f.id]} /></span></div>
            ))}
          </div>
        </div>
      )}
      <InfoExtras extra={task.extra} />
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


function formatElapsed(ms: number): string {
  const s = Math.floor(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}` : `${m}:${String(sec).padStart(2, '0')}`;
}

/** 場所・会議URL・リンク・添付・通知など（予定とタスクで共通の表示：Q62） */
export function InfoExtras({ extra }: { extra: Task['extra'] }) {
  if (!extra) return null;
  const rows: { icon: IconName; label: string; value: React.ReactNode }[] = [];
  if (extra.place) rows.push({ icon: 'flag', label: '場所', value: extra.place.lat != null ? <a className="tint" href={`https://www.openstreetmap.org/?mlat=${extra.place.lat}&mlon=${extra.place.lng}#map=17/${extra.place.lat}/${extra.place.lng}`} target="_blank" rel="noreferrer noopener">{extra.place.name}</a> : extra.place.name });
  if (extra.travelMinutes) rows.push({ icon: 'run', label: '移動', value: `${extra.travelMinutes}分` });
  if (extra.meetingUrl) rows.push({ icon: 'link', label: '会議', value: <a className="tint" href={extra.meetingUrl} target="_blank" rel="noreferrer noopener">参加する</a> });
  for (const u of extra.urls ?? []) rows.push({ icon: 'link', label: u.title || 'リンク', value: <a className="tint" href={u.url} target="_blank" rel="noreferrer noopener">開く</a> });
  if (extra.attachments?.length) rows.push({ icon: 'paint', label: '添付', value: `${extra.attachments.length}件` });
  if (!rows.length) return null;
  return (
    <div className="group" data-testid="info-extras"><div className="group-body">
      {rows.map((r, i) => <div className="row" key={i}><Icon name={r.icon} size={18} className="muted" /><span className="row-label">{r.label}</span><span className="row-value">{r.value}</span></div>)}
    </div></div>
  );
}
