import { useEffect, useId, useState } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  canAddSubtask, delayInfo, ETA_REASON_JA, subtaskLabel, estimateEnd, formatDuration, formatHm, idealProgress,
  workedMs, type Task, type TaskAction,
} from '@my-time/domain';
import { formatOverMinutes } from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Icon, type IconName } from '../../components/Icon';
import { TaskBadge } from '../../components/Identity';
import { Toggle } from '../../components/Controls';
import { progressOf } from '../../app/progress';
import { ProgressPopup } from './ProgressPanel';
import { MapPreview, travelLabel } from '../editor/place';
import { DatePickerPopup, notifySummary, TimeWheelPopup } from '../editor/pickers';
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
import type { PlaceValue, Subtask } from '@my-time/domain';


const LOG_JA: Record<string, string> = {
  create: '作成', update: '編集', start: '開始', pause: '一時停止', resume: '再開', finish: '終了', undoFinish: '完了を取り消し',
  undoStart: '開始を取り消し', progress: '実績を入力', check: 'チェック', uncheck: 'チェックを解除', convert: '種類を変更', move: '時間を移動',
  complete: 'サブタスク完了', uncomplete: 'サブタスク完了を取り消し', delete: '削除',
};

export function TaskDetailSheet({ id, depth, openProgress }: { id: string; depth: number; openProgress?: boolean }) {
  const { tasks, events, calendarById, studioTypes } = useData();
  const [progressOpen, setProgressOpen] = useState(!!openProgress);
  const headId = useId();
  const { closeSheet, openSheet, confirm, showToast } = useUIActions();
  const now = useNow(5_000);
  const task = tasks.find((t) => t.id === id);
  const subtasks = useSubtasks(id);
  const [newSub, setNewSub] = useState('');
  const [subEdit, setSubEdit] = useState<Subtask | null>(null);
  const logs = useLiveQuery(() => db.operationLog.where('entityId').equals(id).reverse().sortBy('seq'), [id]);

  if (!task) {
    return (
      <Sheet onClose={closeSheet} depth={depth} title="タスク" left={<button className="bar-btn" onClick={closeSheet}>閉じる</button>}>
        <p className="empty-note">このタスクは削除されました。</p>
      </Sheet>
    );
  }

  const ideal = idealProgress(task, now);
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
    // 未完了のサブタスクが残っていれば確認（子は自動で完了にしない：R1）
    const open = subtasks.filter((x) => !x.done).length;
    if (open && !(await confirm({ title: '未完了のサブタスクがあります', message: `${open}件が未完了のまま親タスクを完了にします。サブタスクはそのまま残ります。`, confirmLabel: '完了にする', cancelLabel: '戻る' }))) return;
    await run('finish');
    showToast('完了しました。取り消すには「完了を取り消す」');
  };
  const st = task.extra?.studio ? studioTypes.find((t) => t.id === task.extra!.studio!.typeId) : undefined;
  const worked = workedMs(task, now);
  const pr = progressOf(task, subtasks, studioTypes, now);
  const notifies = task.extra?.notifies !== undefined ? task.extra.notifies : task.notifyMinutesBefore != null ? [task.notifyMinutesBefore] : [];
  const place: PlaceValue | null = task.extra?.place ?? (task.location ? { name: task.location, address: '', lat: null, lng: null } : null);

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
      labelledBy={headId}
      left={<button type="button" className="bar-btn" onClick={closeSheet}>閉じる</button>}
      right={<button type="button" className="gbtn glass glass-i tint" aria-label="編集" onClick={() => openSheet({ kind: 'edit', mode: 'task', id: task.id })} data-testid="info-edit"><Icon name="pencil" size={18} /></button>}
      detent="medium"
      detents={['medium', 'large']}
      testId="task-info"
    >
      <ProgressPopup task={task} subtasks={subtasks} open={progressOpen} onClose={() => setProgressOpen(false)} now={now} />
      <div className="detail-hero">
        {task.kind === 'check' && <TaskBadge icon={task.icon} kind="check" size={56} done={!!task.checked} />}
        <h2 id={headId} className="detail-title">{task.title}</h2>
        <div className="detail-meta">
          {task.kind === 'check' ? '確認タスク' : st ? st.name : task.special === 'assignment' ? '課題' : task.special === 'testPrep' ? 'テスト対策' : '実行タスク'}
          {task.category ? ` · ${task.category}` : ''}
          {task.flagged && <span className="flag-mark" role="img" aria-label="フラグ付き"><Icon name="flag" size={15} strokeWidth={2.2} /></span>}
          {task.priority > 0 && <span className="prio-mark" role="img" aria-label={`優先度${['', '低', '中', '高'][task.priority]}`}>{Array.from({ length: task.priority }, (_, i) => <Icon key={i} name="exclamation" size={14} strokeWidth={2.6} />)}</span>}
          {task.autoReserved && <span className="ar-badge">AR</span>}
        </div>
        {task.tags.length > 0 && <div className="tag-line">{task.tags.map((t) => <span key={t} className="tag">#{t}</span>)}</div>}
      </div>
      {/* 実行パネル（Q35・Q92）：名前と進捗リング → 見積／経過 → 大きな主ボタン */}
      {task.kind === 'do' && (
        <div className="run-panel" data-testid="run-panel">
          <button type="button" className="run-ring" onClick={() => setProgressOpen(true)} aria-label={`進捗 ${pr.value == null ? '未入力' : `${Math.round(pr.value * 100)}%`}（${pr.basis}）。タップで変更`} data-testid="run-ring">
            <Ring value={pr.value} size={64} icon={task.icon} kind="do" done={task.status === 'done'} ideal={ideal} running={task.status === 'running'} label={`進捗 ${pr.value == null ? '未入力' : `${Math.round(pr.value * 100)}%`}`} />
          </button>
          <div className="run-time" aria-live="polite" data-testid="run-time">
            {task.status === 'running' || task.status === 'paused' ? <><span className="run-elapsed">{formatElapsed(worked)}</span><span className="muted small">{task.status === 'paused' ? '一時停止中' : '実行中'}</span></>
              : task.status === 'done' ? <><span className="run-elapsed">{formatElapsed(worked)}</span><span className="muted small">完了</span></>
              : <><span className="run-elapsed">{task.estimateMinutes != null ? `${task.estimateMinutes}分` : '0:00'}</span><span className="muted small">{task.estimateMinutes != null ? '見積時間' : '見積なし'}</span></>}
            <span className="muted small" data-testid="run-progress">{pr.source === 'none' ? '実績 未入力' : `${pr.label}${pr.source === 'studio' ? '' : ''}`}</span>
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

      {/* 場所は1か所だけ（新しい値を優先し、旧データだけのときは互換表示：F3）。その直下に地図（C06） */}
      {place && (
        <>
          <div className="group-header">場所</div>
          <MapPreview place={place} />
          {task.extra?.travelMinutes ? <p className="muted small info-travel">{travelLabel(task.extra.travelMinutes)}{task.plannedStart != null ? `（出発の目安 ${formatHm(task.plannedStart - task.extra.travelMinutes * 60_000)}）` : ''}</p> : null}
        </>
      )}
      <div className="group">
        <div className="group-body">
          {/* 通知は全件（extra.notifies があれば空でもそれを優先し、旧データだけ単一値：F1） */}
          <div className="row"><Icon name="bell" size={18} className="muted" /><span className="row-label">通知</span><span className="row-value" data-testid="info-notify">{notifySummary(notifies)}</span></div>
          <div className="row"><Icon name="calendar" size={18} className="muted" /><span className="row-label">カレンダー</span><span className="row-value"><span className="cal-dot" style={{ background: cal?.color ?? 'var(--gray)' }} />{cal?.name ?? 'なし'}</span></div>
          {task.repeat && <div className="row"><Icon name="undo" size={18} className="muted" /><span className="row-label">繰り返し</span><span className="row-value">{{ daily: '毎日', weekly: '毎週', monthly: '毎月' }[task.repeat.freq]}（完了すると次を作成）</span></div>}
          {source && (
            <button type="button" className="row row-button" onClick={() => openSheet({ kind: 'info', entity: 'event', id: source.id })}>
              <Icon name="graduation" size={18} className="muted" />
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
        <div className="group" data-testid="progress-group">
          <div className="group-header">進捗</div>
          <div className="group-body padded">
            <ProgressLine label="理想（予定の時間から）" value={ideal} tone="ideal" />
            <ProgressLine label={`実績（${PR_SRC[pr.source]}）`} value={pr.value} tone="actual" text={pr.source === 'none' ? '未入力' : pr.source === 'subtasks' || pr.source === 'studio' ? `${pr.label}（${Math.round((pr.value ?? 0) * 100)}%）` : pr.label} />
          </div>
          <div className="group-footer">{pr.basis}。{pr.source === 'done' && pr.openSubtasks ? `未完了のサブタスク${pr.openSubtasks}件。` : ''}リングをタップすると変更できます。</div>
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
                <span className={`row-label ${s.done ? 'struck' : ''}`}>{s.title}{subTimeText(s) && <span className="sub-label" data-testid="sub-time">{subTimeText(s)}</span>}</span>
                <button type="button" className="sub-time-btn" aria-label={`${s.title}の日時と見積`} onClick={() => setSubEdit(s)} data-testid={`sub-time-${s.id}`}><Icon name="clock" size={17} /></button>
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
      <WorkLog task={task} logs={logs ?? []} />

      {task.notes && (
        <div className="group">
          <div className="group-header">メモ</div>
          <div className="group-body padded notes">{task.notes}</div>
        </div>
      )}

      <SubtaskTimePopup sub={subEdit} parentStart={task.plannedStart} onClose={() => setSubEdit(null)} />
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

const PR_SRC: Record<string, string> = { done: '完了', studio: '専用の項目', subtasks: 'サブタスク', manual: '手動', none: '未入力' };

function ProgressLine({ label, value, tone, text }: { label: string; value: number | null; tone: 'ideal' | 'actual'; text?: string }) {
  return (
    <div className="pline">
      <div className="pline-head">
        <span>{label}</span>
        <span className="pline-val">{text ?? (value == null ? '未入力' : `${Math.round(value * 100)}%`)}</span>
      </div>
      <div className="pline-track">
        <div className={`pline-fill ${tone}`} style={{ width: `${Math.round((value ?? 0) * 100)}%` }} />
      </div>
    </div>
  );
}

const md = (t: number) => { const d = new Date(t); return `${d.getMonth() + 1}/${d.getDate()}`; };
/** サブタスクの日時・見積の短い表示（C07） */
export function subTimeText(s: Subtask): string {
  const parts: string[] = [];
  if (s.plannedStart != null) {
    const crossing = s.plannedEnd != null && new Date(s.plannedEnd).toDateString() !== new Date(s.plannedStart).toDateString();
    parts.push(`${md(s.plannedStart)} ${formatHm(s.plannedStart)}${s.plannedEnd != null ? `〜${crossing ? `${md(s.plannedEnd)} ` : ''}${formatHm(s.plannedEnd)}` : ''}`);
  }
  if (s.estimateMinutes != null) parts.push(`見積${s.estimateMinutes}分`);
  return parts.join(' · ');
}

/** 実績ログ（C08）：初期は折りたたみ。作業区間と操作履歴を見出しで分け、日付ごとにまとめる（元のログは変えない） */
function WorkLog({ task, logs }: { task: Task; logs: { seq?: number; id?: string; action: string; at: number; detail?: Record<string, unknown> }[] }) {
  const [open, setOpen] = useState(false);
  const panelId = useId();
  const reduce = useReducedMotion();
  const count = task.intervals.length + logs.length;
  const dayKey = (t: number) => { const d = new Date(t); return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`; };
  const group = <T,>(items: T[], at: (x: T) => number) => {
    const m = new Map<string, T[]>();
    for (const x of [...items].sort((a, b) => at(b) - at(a))) { const k = dayKey(at(x)); m.set(k, [...(m.get(k) ?? []), x]); }
    return [...m.entries()];
  };
  return (
    <div className="group" data-testid="work-log">
      <div className="group-body">
        <button type="button" className="row row-button log-toggle" aria-expanded={open} aria-controls={panelId} onClick={() => setOpen((o) => !o)} data-testid="log-toggle">
          <Icon name="clock" size={18} className="muted" />
          <span className="row-label">実績ログ</span>
          <span className="row-value">{count}件</span>
          <Icon name="chevronRight" size={16} className={`chev ${open ? 'rot90' : ''}`} />
        </button>
        <AnimatePresence initial={false}>
          {open && (
            <motion.div id={panelId} key="log" className="log-body" initial={reduce ? false : { height: 0, opacity: 0 }} animate={{ height: 'auto', opacity: 1 }} exit={reduce ? { opacity: 0 } : { height: 0, opacity: 0 }} transition={{ duration: reduce ? 0 : 0.24 }}>
              {count === 0 && <div className="row"><span className="row-label muted">記録はまだありません</span></div>}
              {task.intervals.length > 0 && <div className="log-sec">作業区間</div>}
              {group(task.intervals, (iv) => iv.start).map(([day, ivs]) => (
                <div key={`iv-${day}`}>
                  <div className="log-day">{day}</div>
                  {ivs.map((iv, i) => {
                    const crosses = iv.end != null && dayKey(iv.end) !== dayKey(iv.start);
                    return (
                      <div className="row log-row" key={`${iv.start}-${i}`}>
                        <span className="row-label tnum">{formatHm(iv.start)}〜{iv.end != null ? `${crosses ? `${md(iv.end)} ` : ''}${formatHm(iv.end)}` : '計測中'}</span>
                        <span className="row-value small muted tnum">{iv.end != null ? formatDuration(iv.end - iv.start) : ''}</span>
                      </div>
                    );
                  })}
                </div>
              ))}
              {logs.length > 0 && <div className="log-sec">操作の履歴</div>}
              {group(logs, (l) => l.at).map(([day, ls]) => (
                <div key={`lg-${day}`}>
                  <div className="log-day">{day}</div>
                  {ls.map((l) => (
                    <div className="row log-row" key={l.seq ?? l.id}>
                      <span className="row-label">{LOG_JA[l.action] ?? l.action}{l.action === 'progress' && typeof l.detail?.value === 'number' && !l.detail?.studioField ? ` ${Math.round((l.detail.value as number) * 100)}%` : ''}</span>
                      <span className="row-value small muted tnum">{formatHm(l.at)}</span>
                    </div>
                  ))}
                </div>
              ))}
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </div>
  );
}

/** サブタスクの日時・見積の編集（C07）。終了だけは不可、終了は開始より後、見積は正の数 */
function SubtaskTimePopup({ sub, parentStart, onClose }: { sub: Subtask | null; parentStart: number | null; onClose: () => void }) {
  const { showToast } = useUIActions();
  const [timed, setTimed] = useState(false);
  const [start, setStart] = useState(0);
  const [end, setEnd] = useState<number | null>(null);
  const [est, setEst] = useState('');
  const [pick, setPick] = useState<null | 'sd' | 'st' | 'ed' | 'et'>(null);
  useEffect(() => {
    if (!sub) return;
    const base = sub.plannedStart ?? parentStart ?? (() => { const d = new Date(); d.setMinutes(0, 0, 0); d.setHours(d.getHours() + 1); return d.getTime(); })();
    setTimed(sub.plannedStart != null); setStart(base); setEnd(sub.plannedEnd ?? null); setEst(sub.estimateMinutes != null ? String(sub.estimateMinutes) : '');
  }, [sub]); // eslint-disable-line react-hooks/exhaustive-deps
  const save = async () => {
    if (!sub) return;
    const e = est.trim() === '' ? null : Number(est);
    try {
      await repo.setSubtaskTime(sub.id, { plannedStart: timed ? start : null, plannedEnd: timed ? end : null, estimateMinutes: e });
      onClose();
    } catch (err) { showToast(err instanceof Error ? err.message : '保存できませんでした'); }
  };
  const d = (t: number) => { const x = new Date(t); return `${x.getMonth() + 1}月${x.getDate()}日（${'日月火水木金土'[x.getDay()]}）`; };
  const setDay = (t: number, day: number) => { const a = new Date(t); const b = new Date(day); a.setFullYear(b.getFullYear(), b.getMonth(), b.getDate()); return a.getTime(); };
  const setTime = (t: number, tm: number) => { const a = new Date(t); const b = new Date(tm); a.setHours(b.getHours(), b.getMinutes(), 0, 0); return a.getTime(); };
  return (
    <>
      <Popup open={!!sub && !pick} title={sub ? `「${sub.title}」の日時` : '日時'} onClose={onClose} onDone={() => void save()} testId="sub-time-popup">
        <div className="group"><div className="group-body">
          <div className="row"><span className="row-label">日時を指定</span><Toggle label="日時を指定" checked={timed} onChange={setTimed} /></div>
          {timed && (
            <>
              <div className="row"><span className="row-label">開始</span><span className="ed-dt-values"><button type="button" className="ed-chipbtn" onClick={() => setPick('sd')}>{d(start)}</button><button type="button" className="ed-chipbtn time" onClick={() => setPick('st')} data-testid="sub-start-time">{formatHm(start)}</button></span></div>
              <div className="row"><span className="row-label">終了（任意）</span><span className="ed-dt-values">
                {end == null ? <button type="button" className="ed-chipbtn" onClick={() => setEnd(start + 30 * 60_000)} data-testid="sub-add-end">追加</button> : (<>
                  <button type="button" className={`ed-chipbtn ${end <= start ? 'danger' : ''}`} onClick={() => setPick('ed')}>{d(end)}</button>
                  <button type="button" className={`ed-chipbtn time ${end <= start ? 'danger' : ''}`} onClick={() => setPick('et')}>{formatHm(end)}</button>
                  <button type="button" className="link-del" aria-label="終了を外す" onClick={() => setEnd(null)}><Icon name="close" size={13} /></button>
                </>)}
              </span></div>
            </>
          )}
          <label className="row"><span className="row-label">見積（分）</span><input className="row-input num" type="number" inputMode="numeric" min={1} value={est} onChange={(e) => setEst(e.target.value)} aria-label="見積（分）" data-testid="sub-estimate" /></label>
        </div></div>
        {timed && end != null && end <= start && <p className="form-error">終了は開始より後にしてください</p>}
        <p className="muted small">サブタスクの時間を決めても、親タスクの実績時間や進捗の重みは変わりません。</p>
      </Popup>
      <DatePickerPopup open={pick === 'sd'} value={start} title="開始日" onClose={() => setPick(null)} onPick={(x) => { setPick(null); const ns = setDay(start, x); if (end != null) setEnd(end + (ns - start)); setStart(ns); }} />
      <TimeWheelPopup open={pick === 'st'} value={start} title="開始時刻" onClose={() => setPick(null)} onPick={(x) => { setPick(null); const ns = setTime(start, x); if (end != null) setEnd(end + (ns - start)); setStart(ns); }} />
      <DatePickerPopup open={pick === 'ed' && end != null} value={end ?? start} min={start} title="終了日" onClose={() => setPick(null)} onPick={(x) => { setPick(null); setEnd(setDay(end ?? start, x)); }} />
      <TimeWheelPopup open={pick === 'et' && end != null} value={end ?? start} title="終了時刻" onClose={() => setPick(null)} onPick={(x) => { setPick(null); setEnd(setTime(end ?? start, x)); }} />
    </>
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
  // 場所と移動は、情報確認の「場所」と地図で1か所だけ表示する（F3）
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
