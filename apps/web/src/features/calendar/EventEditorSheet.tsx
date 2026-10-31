import { useId, useMemo, useState } from 'react';
import { findConflicts, formatHm, HOUR, makeEvent, startOfDay, suggestFreeSlot, type CalEvent } from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Icon } from '../../components/Icon';
import { useData } from '../../app/data';
import { useUI } from '../../app/ui';
import { fromLocalInput, toLocalInput } from '../../app/format';
import { repo } from '../../data/repo';
import { defaultStartFor } from '../tasks/TaskEditorSheet';

export function EventEditorSheet({ eventId, defaults, depth }: { eventId?: string; defaults?: Partial<CalEvent>; depth: number }) {
  const { events, calendars } = useData();
  const { closeSheet, calDate, tab, homeDate, confirm, showToast } = useUI();
  const existing = eventId ? events.find((e) => e.id === eventId) : undefined;
  const isNew = !existing;
  const fid = useId();
  const baseDay = tab === 'calendar' ? calDate : homeDate;
  const s0 = existing?.start ?? defaults?.start ?? defaultStartFor(baseDay, Date.now());
  const [title, setTitle] = useState(existing?.title ?? defaults?.title ?? '');
  const [calendarId, setCalendarId] = useState(existing?.calendarId ?? defaults?.calendarId ?? calendars[0]?.id ?? 'cal-general');
  const [start, setStart] = useState(toLocalInput(s0));
  const [end, setEnd] = useState(toLocalInput(existing?.end ?? defaults?.end ?? s0 + HOUR));
  const [notes, setNotes] = useState(existing?.notes ?? '');
  const [error, setError] = useState<string | null>(null);

  const ps = fromLocalInput(start);
  const pe = fromLocalInput(end);
  const target = ps != null && pe != null && pe > ps ? { id: existing?.id ?? '__new', start: ps, end: pe } : null;
  const conflicts = useMemo(() => (target ? findConflicts(target, events) : []), [target?.start, target?.end, events]); // eslint-disable-line react-hooks/exhaustive-deps
  const suggestion = target && conflicts.length ? suggestFreeSlot(target, events, startOfDay(target.start)) : null;

  const onStartChange = (v: string) => {
    const ns = fromLocalInput(v);
    setStart(v);
    if (ps != null && pe != null && ns != null && pe > ps) setEnd(toLocalInput(ns + (pe - ps)));
  };

  const save = async () => {
    setError(null);
    if (!title.trim()) return setError('タイトルを入力してください');
    if (!target) return setError('終了は開始より後にしてください');
    try {
      if (isNew) await repo.saveEvent(makeEvent({ title: title.trim(), calendarId, start: target.start, end: target.end, notes }, Date.now()), true);
      else await repo.saveEvent({ ...existing, title: title.trim(), calendarId, start: target.start, end: target.end, notes }, false);
      showToast(isNew ? '予定を追加しました' : '保存しました');
      closeSheet();
    } catch (e) {
      setError(e instanceof Error ? e.message : '保存できませんでした');
    }
  };

  const remove = async () => {
    if (!existing) return;
    const ok = await confirm({ title: '予定を削除しますか？', message: `「${existing.title}」を削除します。`, confirmLabel: '削除', destructive: true });
    if (!ok) return;
    await repo.deleteEvent(existing.id);
    closeSheet();
    showToast('削除しました');
  };

  return (
    <Sheet
      onClose={closeSheet}
      depth={depth}
      title={isNew ? '新規予定' : '予定を編集'}
      left={<button type="button" className="bar-btn" onClick={closeSheet}>キャンセル</button>}
      right={<button type="button" className="bar-btn bold" onClick={() => void save()} data-testid="save-event">{isNew ? '追加' : '完了'}</button>}
    >
      <form className="form" onSubmit={(e) => { e.preventDefault(); void save(); }}>
        <div className="group">
          <div className="group-body">
            <input className="row-input big" value={title} onChange={(e) => setTitle(e.target.value)} placeholder="タイトル" aria-label="タイトル" autoFocus={isNew} data-testid="event-title-input" />
          </div>
        </div>
        <div className="group">
          <div className="group-body">
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-s`}>開始</label>
              <input id={`${fid}-s`} type="datetime-local" className="dt-input" value={start} onChange={(e) => onStartChange(e.target.value)} data-testid="event-start" />
            </div>
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-e`}>終了</label>
              <input id={`${fid}-e`} type="datetime-local" className="dt-input" value={end} onChange={(e) => setEnd(e.target.value)} data-testid="event-end" />
            </div>
          </div>
          {conflicts.length > 0 && (
            <div className="conflict" role="status" data-testid="conflict-warning">
              <Icon name="info" size={18} />
              <div>
                <div>「{conflicts[0]!.title}」{conflicts.length > 1 ? `など${conflicts.length}件` : ''}と時間が重なっています。</div>
                {suggestion && (
                  <button type="button" className="link-btn" onClick={() => { setStart(toLocalInput(suggestion.start)); setEnd(toLocalInput(suggestion.end)); }}>
                    {formatHm(suggestion.start)}〜{formatHm(suggestion.end)} に変更する
                  </button>
                )}
                <div className="conflict-note">既存の予定は自動で移動しません。</div>
              </div>
            </div>
          )}
        </div>
        <div className="group">
          <div className="group-body">
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-cal`}>カレンダー</label>
              <select id={`${fid}-cal`} className="select-input" value={calendarId} onChange={(e) => setCalendarId(e.target.value)}>
                {calendars.map((c) => (
                  <option key={c.id} value={c.id}>{c.name}</option>
                ))}
              </select>
            </div>
          </div>
        </div>
        <div className="group">
          <div className="group-body">
            <textarea className="row-input notes-input" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="メモ" aria-label="メモ" rows={3} />
          </div>
        </div>
        {error && <p className="form-error" role="alert">{error}</p>}
        {!isNew && (
          <div className="group">
            <div className="group-body">
              <button type="button" className="row row-button destructive center" onClick={() => void remove()} data-testid="delete-event">予定を削除</button>
            </div>
          </div>
        )}
        <button type="submit" hidden />
      </form>
    </Sheet>
  );
}
