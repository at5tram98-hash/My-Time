import { useMemo, useState } from 'react';
import { addDays, checkPlacement, copyToDays, expandAll, expandEvent, isSameDay, parseOccurrenceId, placementItems, startOfDay, wall, weekday } from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Icon } from '../../components/Icon';
import { useData } from '../../app/data';
import { useUI } from '../../app/ui';
import { formatMonth } from '../../app/format';
import { repo } from '../../data/repo';

/** 予定を複数の日へコピー。既存の予定が見える縮小カレンダーで日付を選ぶ（既存の予定は動かさない） */
export function CopyEventSheet({ eventId, depth }: { eventId: string; depth: number }) {
  const { events, tasks, calendarById } = useData();
  const { closeSheet, confirm, showToast } = useUI();
  const occ = parseOccurrenceId(eventId);
  const master = events.find((e) => e.id === (occ?.masterId ?? eventId));
  const source = useMemo(() => {
    if (!master) return null;
    if (!occ) return master;
    return expandEvent(master, occ.originalStart - 8 * 86_400_000, occ.originalStart + 8 * 86_400_000).find((o) => o.id === eventId) ?? master;
  }, [master, occ?.originalStart, eventId]); // eslint-disable-line react-hooks/exhaustive-deps
  const [month, setMonth] = useState(() => {
    const w = wall(source?.start ?? Date.now());
    return startOfDay(new Date(w.y, w.mo, 1).getTime());
  });
  const [picked, setPicked] = useState<number[]>([]);

  const gridStart = addDays(month, -weekday(month));
  const cells = Array.from({ length: 42 }, (_, i) => addDays(gridStart, i));
  const shown = useMemo(() => expandAll(events, gridStart, addDays(gridStart, 42)), [events, gridStart]);
  if (!source) return null;

  const toggle = (d: number) => setPicked((p) => (p.includes(d) ? p.filter((x) => x !== d) : [...p, d].sort((a, b) => a - b)));
  const shift = (n: number) => {
    const w = wall(month);
    setMonth(startOfDay(new Date(w.y, w.mo + n, 1).getTime()));
  };

  const apply = async () => {
    if (!picked.length) return;
    const copies = copyToDays(source, picked, () => 'preview', Date.now());
    const items = placementItems(expandAll(events, picked[0]! - 86_400_000, picked.at(-1)! + 2 * 86_400_000), tasks);
    const overlapping = copies.filter((c) => checkPlacement({ id: 'copy', start: c.start, end: c.end }, items).conflicts.length > 0).length;
    if (overlapping > 0) {
      const ok = await confirm({ title: '時間が重なる日があります', message: `${overlapping}日分は既存の予定と重なります。既存の予定は動かしません。このままコピーしますか？`, confirmLabel: 'コピー' });
      if (!ok) return;
    }
    const n = await repo.copyEventToDays(source, picked);
    showToast(`${n}日にコピーしました`);
    closeSheet();
  };

  return (
    <Sheet
      onClose={closeSheet}
      depth={depth}
      title="別の日にコピー"
      left={<button type="button" className="bar-btn" onClick={closeSheet}>キャンセル</button>}
      right={<button type="button" className="bar-btn bold" disabled={!picked.length} onClick={() => void apply()} data-testid="apply-copy">{picked.length ? `${picked.length}日にコピー` : 'コピー'}</button>}
    >
      <p className="sheet-lead">「{source.title}」をコピーする日を選んでください。点は既にある予定です。</p>
      <div className="mini-cal" data-testid="mini-cal">
        <div className="mini-cal-head">
          <button type="button" className="icon-btn" aria-label="前の月" onClick={() => shift(-1)}><Icon name="chevronLeft" size={20} /></button>
          <span>{formatMonth(month)}</span>
          <button type="button" className="icon-btn" aria-label="次の月" onClick={() => shift(1)}><Icon name="chevronRight" size={20} /></button>
        </div>
        <div className="mini-cal-grid">
          {['日', '月', '火', '水', '木', '金', '土'].map((w) => (
            <span key={w} className="mini-wd">{w}</span>
          ))}
          {cells.map((d) => {
            const dayEvents = shown.filter((e) => e.start < addDays(d, 1) && e.end > d);
            const inMonth = wall(d).mo === wall(month).mo;
            const isSource = isSameDay(d, source.start);
            return (
              <button
                key={d}
                type="button"
                className={`mini-day ${inMonth ? '' : 'out'} ${picked.includes(d) ? 'on' : ''} ${isSource ? 'source' : ''}`}
                aria-pressed={picked.includes(d)}
                aria-label={`${wall(d).mo + 1}月${wall(d).d}日、予定${dayEvents.length}件`}
                disabled={isSource}
                onClick={() => toggle(d)}
                data-testid={`copy-day-${wall(d).d}-${inMonth ? 'in' : 'out'}`}
              >
                <span className="mini-num">{wall(d).d}</span>
                <span className="mini-dots" aria-hidden>
                  {dayEvents.slice(0, 3).map((e) => (
                    <i key={e.id} style={{ background: calendarById.get(e.calendarId)?.color ?? 'var(--blue)' }} />
                  ))}
                </span>
              </button>
            );
          })}
        </div>
      </div>
    </Sheet>
  );
}
