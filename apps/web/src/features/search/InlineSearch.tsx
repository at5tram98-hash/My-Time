import { useEffect, useMemo, useRef, useState } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { formatDayLabel, formatHm, startOfDay } from '@my-time/domain';
import { Icon } from '../../components/Icon';
import { ItemIcon } from '../../components/ItemIcon';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { SPRING } from '../../ui/motion';

/**
 * コンパクトな検索（Q19・Q31・Q40）。小さなガラスボタンから上部に検索欄が広がり、直下に候補を出す。
 * 全画面の別画面には切り替えない。結果をタップすると該当日へ移動し、情報確認を開く。
 */
export function InlineSearch({ target, scope = 'all' }: { target: 'home' | 'calendar' | 'tasks'; scope?: 'all' | 'tasks' }) {
  const { tasks, events } = useData();
  const { setHomeDate, setCalDate, openSheet } = useUIActions();
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState('');
  const reduce = useReducedMotion();
  const inputRef = useRef<HTMLInputElement>(null);
  useEffect(() => { if (open) requestAnimationFrame(() => inputRef.current?.focus()); else setQ(''); }, [open]);
  const results = useMemo(() => {
    const k = q.trim().toLowerCase();
    if (!k) return [];
    const m = (s: string | null | undefined) => (s ?? '').toLowerCase().includes(k);
    return [
      ...tasks.filter((t) => m(t.title) || m(t.notes) || m(t.category)).map((t) => ({ type: 'task' as const, id: t.id, title: t.title, icon: t.icon, at: t.plannedStart ?? t.checkAt })),
      ...(scope === 'all' ? events.filter((e) => m(e.title) || m(e.notes) || m(e.extra?.place?.name)).map((e) => ({ type: 'event' as const, id: e.id, title: e.title, icon: 'calendar', at: e.start as number | null })) : []),
    ].sort((a, b) => (b.at ?? 0) - (a.at ?? 0)).slice(0, 30);
  }, [q, tasks, events, scope]);

  const go = (r: (typeof results)[number]) => {
    setOpen(false);
    if (r.at != null) (target === 'calendar' ? setCalDate : setHomeDate)(startOfDay(r.at));
    openSheet({ kind: 'info', entity: r.type, id: r.id });
  };

  return (
    <>
      <button type="button" className="gbtn glass glass-i" aria-label="検索" aria-expanded={open} onClick={() => setOpen(true)} data-testid={`${target}-search`}><Icon name="search" size={19} /></button>
      <AnimatePresence>
        {open && (
          <motion.div className="isearch" initial={reduce ? { opacity: 0 } : { opacity: 0, scaleX: 0.3 }} animate={{ opacity: 1, scaleX: 1 }} exit={reduce ? { opacity: 0 } : { opacity: 0, scaleX: 0.3 }} transition={reduce ? { duration: 0.08 } : SPRING.pop} style={{ transformOrigin: 'right center' }}>
            <form className="isearch-bar glass" role="search" onSubmit={(e) => e.preventDefault()}>
              <Icon name="search" size={17} />
              <input ref={inputRef} type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder={scope === 'tasks' ? 'タスクを検索' : 'タスク・予定を検索'} aria-label="検索語" enterKeyHint="search" data-testid="search-input" onKeyDown={(e) => e.key === 'Escape' && setOpen(false)} />
              <button type="button" className="bar-btn" onClick={() => setOpen(false)}>キャンセル</button>
            </form>
            {q.trim() && (
              <div className="isearch-results glass" role="listbox" aria-label="検索結果" data-testid="search-results">
                {results.length === 0 && <div className="row muted">見つかりません</div>}
                {results.map((r) => (
                  <button key={`${r.type}-${r.id}`} type="button" role="option" aria-selected={false} className="row row-button" onClick={() => go(r)} data-testid="search-result">
                    <ItemIcon value={r.icon} size={18} className={r.type === 'task' ? 'tint' : 'muted'} />
                    <span className="row-label">{r.title}<span className="sub-label">{r.type === 'task' ? 'タスク' : '予定'}</span></span>
                    <span className="row-value small muted">{r.at != null ? `${formatDayLabel(r.at)} ${formatHm(r.at)}` : '未設定'}</span>
                  </button>
                ))}
              </div>
            )}
          </motion.div>
        )}
      </AnimatePresence>
    </>
  );
}
