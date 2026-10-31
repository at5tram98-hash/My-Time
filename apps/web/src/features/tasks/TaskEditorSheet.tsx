import { useId, useMemo, useState } from 'react';
import { HOUR, makeTask, previewConversion, startOfDay, type Task, type TaskKind } from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Segmented, Toggle } from '../../components/Controls';
import { useData } from '../../app/data';
import { usePlacementGuard } from '../../app/usePlacementGuard';
import { useUI } from '../../app/ui';
import { fromLocalInput, toLocalInput } from '../../app/format';
import { db } from '../../data/db';
import { repo } from '../../data/repo';

export const TASK_ICONS = ['📘', '✏️', '💻', '📝', '📚', '🧪', '🎯', '💼', '🏃', '🧹', '🛒', '🍳', '🎧', '💬', '💡', '⭐️'];

/** 次のきりのよい時刻（その日の範囲内） */
export function defaultStartFor(day: number, now: number): number {
  const base = startOfDay(day) === startOfDay(now) ? now : startOfDay(day) + 9 * HOUR;
  const d = new Date(base);
  d.setMinutes(d.getMinutes() > 0 ? 60 : 0, 0, 0);
  return d.getTime();
}

export function TaskEditorSheet({ taskId, defaults, depth }: { taskId?: string; defaults?: Partial<Task>; depth: number }) {
  const { tasks, calendars } = useData();
  const { closeSheet, homeDate, confirm, showToast } = useUI();
  const existing = taskId ? tasks.find((t) => t.id === taskId) : undefined;
  const isNew = !existing;
  const init = existing ?? ({ ...defaults } as Partial<Task>);
  const fid = useId();
  const guard = usePlacementGuard();

  const startDefault = defaultStartFor(homeDate, Date.now());
  const [title, setTitle] = useState(init.title ?? '');
  const [kind, setKind] = useState<TaskKind>(init.kind ?? 'do');
  const [icon, setIcon] = useState(init.icon ?? TASK_ICONS[0]!);
  const [calendarId, setCalendarId] = useState<string>(init.calendarId ?? '');
  const [category, setCategory] = useState(init.category ?? '');
  const [timed, setTimed] = useState(isNew ? (defaults?.plannedStart !== null) : init.plannedStart != null);
  const [start, setStart] = useState(toLocalInput(init.plannedStart ?? startDefault));
  const [end, setEnd] = useState(toLocalInput(init.plannedEnd ?? (init.plannedStart ?? startDefault) + HOUR));
  const [checkTimed, setCheckTimed] = useState(isNew ? true : init.checkAt != null);
  const [checkAt, setCheckAt] = useState(toLocalInput(init.checkAt ?? startDefault));
  const [notes, setNotes] = useState(init.notes ?? '');
  const [error, setError] = useState<string | null>(null);

  const categories = useMemo(() => [...new Set(tasks.map((t) => t.category).filter((c): c is string => !!c))], [tasks]);

  const onStartChange = (v: string) => {
    // 開始を動かしたら長さを保って終了も動かす
    const os = fromLocalInput(start);
    const oe = fromLocalInput(end);
    const ns = fromLocalInput(v);
    setStart(v);
    if (os != null && oe != null && ns != null && oe > os) setEnd(toLocalInput(ns + (oe - os)));
  };

  const save = async () => {
    setError(null);
    if (!title.trim()) return setError('タイトルを入力してください');
    const ps = kind === 'do' && timed ? fromLocalInput(start) : null;
    const pe = kind === 'do' && timed ? fromLocalInput(end) : null;
    if (kind === 'do' && timed && (ps == null || pe == null || pe <= ps)) return setError('終了は開始より後にしてください');
    // 時刻を新しく決めた／変えたときは保存前に重複を確認（キャンセルなら何も保存しない）
    let [ps2, pe2] = [ps, pe];
    if (ps != null && pe != null && (isNew || existing.plannedStart !== ps || existing.plannedEnd !== pe)) {
      const decision = await guard({ id: `task:${existing?.id ?? '__new'}`, start: ps, end: pe }, '保存');
      if (!decision) return;
      [ps2, pe2] = [decision.start, decision.end];
    }
    const fields: Partial<Task> = {
      title: title.trim(),
      icon,
      calendarId: calendarId || null,
      category: category.trim() || null,
      notes,
      ...(kind === 'do' ? { plannedStart: ps2, plannedEnd: pe2 } : { checkAt: checkTimed ? fromLocalInput(checkAt) : null }),
    };
    try {
      if (isNew) {
        await repo.saveTask(makeTask({ ...defaults, ...fields, title: title.trim(), kind }, Date.now()), true);
        showToast('追加しました');
      } else {
        if (existing.kind !== kind) {
          const pv = previewConversion(existing, kind);
          const ok = await confirm({
            title: kind === 'check' ? '確認タスクに変更しますか？' : '実施タスクに変更しますか？',
            message: pv.warnings.join('\n') || '実績の記録は保持されます。',
            confirmLabel: '変更',
          });
          if (!ok) return;
          await repo.convertTask(existing.id, kind);
        }
        const fresh = (await db.tasks.get(existing.id)) ?? existing;
        await repo.saveTask({ ...fresh, ...fields }, false);
      }
      closeSheet();
    } catch (e) {
      setError(e instanceof Error ? e.message : '保存できませんでした');
    }
  };

  return (
    <Sheet
      onClose={closeSheet}
      depth={depth}
      title={isNew ? '新規タスク' : 'タスクを編集'}
      left={<button type="button" className="bar-btn" onClick={closeSheet}>キャンセル</button>}
      right={<button type="button" className="bar-btn bold" onClick={() => void save()} data-testid="save-task">{isNew ? '追加' : '完了'}</button>}
    >
      <form
        className="form"
        onSubmit={(e) => {
          e.preventDefault();
          void save();
        }}
      >
        <div className="group">
          <div className="group-body">
            <input className="row-input big" value={title} onChange={(e) => setTitle(e.target.value)} placeholder="タイトル" aria-label="タイトル" autoFocus={isNew} data-testid="task-title-input" />
            <textarea className="row-input notes-input" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="メモ" aria-label="メモ" rows={2} />
          </div>
        </div>

        <div className="form-center">
          <Segmented label="タスクの種類" value={kind} onChange={setKind} options={[{ value: 'do', label: '実施' }, { value: 'check', label: '確認' }]} />
        </div>

        <div className="group">
          <div className="group-header">アイコン</div>
          <div className="group-body padded">
            <div className="icon-grid" role="radiogroup" aria-label="アイコン">
              {TASK_ICONS.map((ic) => (
                <button key={ic} type="button" role="radio" aria-checked={ic === icon} className={`icon-choice ${ic === icon ? 'on' : ''}`} onClick={() => setIcon(ic)}>
                  {ic}
                </button>
              ))}
            </div>
          </div>
        </div>

        <div className="group">
          <div className="group-body">
            {kind === 'do' ? (
              <>
                <div className="row">
                  <label className="row-label" htmlFor={`${fid}-timed`}>日時を指定</label>
                  <Toggle id={`${fid}-timed`} label="日時を指定" checked={timed} onChange={setTimed} />
                </div>
                {timed && (
                  <>
                    <div className="row">
                      <label className="row-label" htmlFor={`${fid}-s`}>開始</label>
                      <input id={`${fid}-s`} type="datetime-local" className="dt-input" value={start} onChange={(e) => onStartChange(e.target.value)} data-testid="task-start" />
                    </div>
                    <div className="row">
                      <label className="row-label" htmlFor={`${fid}-e`}>終了</label>
                      <input id={`${fid}-e`} type="datetime-local" className="dt-input" value={end} onChange={(e) => setEnd(e.target.value)} data-testid="task-end" />
                    </div>
                  </>
                )}
              </>
            ) : (
              <>
                <div className="row">
                  <label className="row-label" htmlFor={`${fid}-ct`}>確認日時</label>
                  <Toggle id={`${fid}-ct`} label="確認日時" checked={checkTimed} onChange={setCheckTimed} />
                </div>
                {checkTimed && (
                  <div className="row">
                    <label className="row-label" htmlFor={`${fid}-c`}>日時</label>
                    <input id={`${fid}-c`} type="datetime-local" className="dt-input" value={checkAt} onChange={(e) => setCheckAt(e.target.value)} />
                  </div>
                )}
              </>
            )}
          </div>
          {kind === 'do' && !timed && <div className="group-footer">日時を指定しないタスクは「未設定」に表示されます。</div>}
        </div>

        <div className="group">
          <div className="group-body">
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-cal`}>カレンダー</label>
              <select id={`${fid}-cal`} className="select-input" value={calendarId} onChange={(e) => setCalendarId(e.target.value)}>
                <option value="">なし</option>
                {calendars.map((c) => (
                  <option key={c.id} value={c.id}>{c.name}</option>
                ))}
              </select>
            </div>
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-cat`}>カテゴリ</label>
              <input id={`${fid}-cat`} className="row-input right" list={`${fid}-cats`} value={category} onChange={(e) => setCategory(e.target.value)} placeholder="なし" />
              <datalist id={`${fid}-cats`}>
                {categories.map((c) => (
                  <option key={c} value={c} />
                ))}
              </datalist>
            </div>
          </div>
        </div>
        {error && <p className="form-error" role="alert">{error}</p>}
        <button type="submit" hidden />
      </form>
    </Sheet>
  );
}
