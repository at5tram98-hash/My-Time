import { useEffect, useState } from 'react';
import { formatDuration, idealProgress, unitLabel, workedMs, type Subtask, type Task } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { progressOf } from '../../app/progress';
import { repo } from '../../data/repo';
import { Icon } from '../../components/Icon';
import { Popup } from '../../ui/Popup';
import { Ring } from '../../ui/Ring';

/**
 * 進捗を変更（C26・F2・R1）。リング・大きな数字・根拠のラベルと、根拠に合った入力だけを出す。
 * - 手動：スライダー（完了で確定、取消で保存しない）
 * - Studio 数値：元の数値項目を更新（目標100ページなら34%→34ページ）。manual には保存しない
 * - サブタスク：子のチェック一覧
 * - 実行時間：経過時間を表示するだけ（スライダーで捏造しない）
 */
export function ProgressPopup({ task, subtasks, open, onClose, now }: { task: Task; subtasks: Subtask[]; open: boolean; onClose: () => void; now: number }) {
  const { studioTypes } = useData();
  const { showToast } = useUIActions();
  const pr = progressOf(task, subtasks, studioTypes, now);
  const [manual, setManual] = useState(0);
  const [num, setNum] = useState('');
  useEffect(() => {
    if (!open) return;
    setManual(Math.round((pr.source === 'manual' ? pr.value ?? 0 : task.manualProgress?.value ?? 0) * 100));
    const f = pr.studioField;
    setNum(f && task.extra?.studio ? String(task.extra.studio.values[f.id] ?? '') : '');
  }, [open]); // eslint-disable-line react-hooks/exhaustive-deps
  const ideal = idealProgress(task, now);
  const studioNumber = pr.source === 'studio' && pr.studioField?.type === 'number' && pr.studioTarget;
  const canManual = pr.source === 'manual' || pr.source === 'none';
  const live = pr.source === 'manual' || pr.source === 'none' ? manual / 100 : studioNumber && num !== '' ? Math.max(0, Math.min(1, Number(num) / pr.studioTarget!)) : pr.value;
  const save = async () => {
    try {
      if (studioNumber && pr.studioField) {
        const n = num === '' ? null : Number(num);
        if (n != null && !(Number.isFinite(n) && n >= 0)) return showToast('0以上の数を入力してください');
        if (n != null && pr.studioField.max != null && n > pr.studioField.max) return showToast(`${pr.studioField.max}以下で入力してください`);
        await repo.setStudioValue(task.id, pr.studioField.id, n == null ? null : +n.toFixed(pr.studioField.precision ?? 0));
      } else if (canManual && task.kind === 'do' && task.status !== 'done') {
        await repo.recordProgress(task.id, manual / 100);
      }
      onClose();
    } catch (e) { showToast(e instanceof Error ? e.message : '保存できませんでした'); }
  };
  const editable = !!studioNumber || (canManual && task.kind === 'do' && task.status !== 'done');
  return (
    <Popup open={open} title="進捗" onClose={onClose} {...(editable ? { onDone: () => void save() } : {})} testId="progress-popup">
      <div className="pp-head">
        <Ring value={live} size={72} icon={task.icon} kind={task.kind === 'check' ? 'check' : 'do'} done={task.status === 'done'} ideal={ideal} />
        <div className="pp-num">
          <strong data-testid="pp-value">{live == null ? '未入力' : `${Math.round(live * 100)}%`}</strong>
          <span className="pp-src">{pr.basis}</span>
          {ideal != null && task.status !== 'done' && <span className="pp-ideal">理想 {Math.round(ideal * 100)}%（予定の時間から計算・実績とは別）</span>}
        </div>
      </div>
      {pr.source === 'done' && pr.openSubtasks > 0 && <p className="note-text warn" role="status">完了済みですが、未完了のサブタスクが{pr.openSubtasks}件あります。</p>}
      {canManual && task.kind === 'do' && task.status !== 'done' && (
        <div className="pp-slider">
          <input type="range" min={0} max={100} step={1} value={manual} onChange={(e) => setManual(Number(e.target.value))} aria-label="実績の進捗（%）" aria-valuetext={`${manual}%`} data-testid="progress-range" />
          <div className="pp-ticks" aria-hidden><span>0</span><span>50</span><span>100%</span></div>
        </div>
      )}
      {studioNumber && pr.studioField && (
        <label className="field inline pp-studio">
          <span className="field-label">{pr.studioField.label}（目標 {pr.studioTarget}{unitLabel(pr.studioField.unit)}）</span>
          <span className="pp-num-in"><input className="row-input num" type="number" inputMode="decimal" min={pr.studioField.min ?? 0} max={pr.studioField.max ?? undefined} value={num} onChange={(e) => setNum(e.target.value)} aria-label={pr.studioField.label} data-testid="pp-studio" />{unitLabel(pr.studioField.unit)}</span>
        </label>
      )}
      {pr.source === 'studio' && !studioNumber && <p className="note-text">この方式の値は編集画面の専用タブで変更します（{pr.label}）。</p>}
      {pr.source === 'subtasks' && (
        <div className="group"><div className="group-body">
          {subtasks.map((s) => (
            <button key={s.id} type="button" role="checkbox" aria-checked={s.done} className="row row-button sel-row" onClick={() => void repo.toggleSubtask(s.id)}>
              <span className={`sel-mark ${s.done ? 'on' : ''}`} aria-hidden>{s.done && <Icon name="check" size={14} strokeWidth={3} />}</span>
              <span className={`row-label ${s.done ? 'struck' : ''}`}>{s.title}</span>
            </button>
          ))}
        </div></div>
      )}
      {task.kind === 'do' && <p className="muted small">作業時間 {formatDuration(workedMs(task, now))}{task.estimateMinutes ? ` / 見積 ${task.estimateMinutes}分` : ''}</p>}
    </Popup>
  );
}
