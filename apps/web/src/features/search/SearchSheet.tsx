import { useMemo, useState } from 'react';
import { formatDayLabel, formatHm, startOfDay } from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Icon } from '../../components/Icon';
import { useData } from '../../app/data';
import { useUI } from '../../app/ui';
import { ItemIcon } from '../../components/ItemIcon';

export function SearchSheet({ depth }: { depth: number }) {
  const { tasks, events } = useData();
  const { closeSheet, openSheet, setHomeDate, setCalDate, tab } = useUI();
  const [q, setQ] = useState('');
  const results = useMemo(() => {
    const k = q.trim().toLowerCase();
    if (!k) return [];
    const match = (s: string) => s.toLowerCase().includes(k);
    return [
      ...tasks.filter((t) => match(t.title) || match(t.notes) || match(t.category ?? '')).map((t) => ({ type: 'task' as const, id: t.id, title: t.title, icon: t.icon, at: t.plannedStart ?? t.checkAt })),
      ...events.filter((e) => match(e.title) || match(e.notes)).map((e) => ({ type: 'event' as const, id: e.id, title: e.title, icon: '', at: e.start as number | null })),
    ].sort((a, b) => (b.at ?? 0) - (a.at ?? 0));
  }, [q, tasks, events]);

  return (
    <Sheet onClose={closeSheet} depth={depth} title="検索" right={<button type="button" className="bar-btn" onClick={closeSheet}>完了</button>}>
      <div className="search-field">
        <Icon name="search" size={18} />
        <input type="search" autoFocus value={q} onChange={(e) => setQ(e.target.value)} placeholder="タスク・予定を検索" aria-label="検索語" enterKeyHint="search" data-testid="search-input" />
      </div>
      <div className="group">
        <div className="group-body">
          {q && results.length === 0 && <div className="row"><span className="row-label muted">見つかりませんでした</span></div>}
          {results.map((r) => (
            <button
              key={`${r.type}-${r.id}`}
              type="button"
              className="row row-button"
              onClick={() => {
                if (r.at != null) {
                  if (tab === 'calendar') setCalDate(startOfDay(r.at));
                  else setHomeDate(startOfDay(r.at));
                }
                closeSheet();
                openSheet(r.type === 'task' ? { kind: 'task', id: r.id } : { kind: 'editEvent', eventId: r.id });
              }}
            >
              <span className="row-label with-icon">{r.type === 'task' ? <ItemIcon value={r.icon} size={18} className="tint" /> : <ItemIcon value="calendar" size={18} className="muted" />}{r.title}</span>
              <span className="row-value small muted">{r.at != null ? `${formatDayLabel(r.at)} ${formatHm(r.at)}` : '未設定'}</span>
            </button>
          ))}
        </div>
      </div>
    </Sheet>
  );
}
