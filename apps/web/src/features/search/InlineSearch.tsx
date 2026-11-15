import { useEffect, useMemo, useRef, useState } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { expandAll, formatDayLabel, formatHm, parseInput, searchItems, startOfDay } from '@my-time/domain';
import { Icon } from '../../components/Icon';
import { EventBadge, TaskBadge } from '../../components/Identity';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { SPRING } from '../../ui/motion';

/**
 * コンパクトな検索（Q19・Q31・Q40）。小さなガラスボタンから上部に検索欄が広がり、直下に候補を出す。
 * 全画面の別画面には切り替えない。結果をタップすると該当日へ移動し、情報確認を開く。
 */
export function InlineSearch({ target, scope = 'all' }: { target: 'home' | 'calendar' | 'tasks'; scope?: 'all' | 'tasks' }) {
  const { tasks, events, calendarById } = useData();
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
    // 「来週のバイト」「金曜の提出物」のような言い方は、日付と種類で探す（P03・P46）
    const pr = parseInput(q, { now: Date.now(), events: [], tasks: [] });
    const semantic = pr.intent === 'search' ? searchItems(pr.query, expandAll(events, Date.now() - 60 * 86_400_000, Date.now() + 120 * 86_400_000), tasks) : [];
    const sem = new Set(semantic.map((h) => `${h.entity}-${h.id}`));
    const tag = k.replace(/^#/, '');
    return [
      ...semantic.filter((h) => scope === 'all' || h.entity === 'task').map((h) => {
        const t = h.entity === 'task' ? tasks.find((x) => x.id === h.id) : undefined;
        const e = h.entity === 'event' ? events.find((x) => x.id === h.id.split('@')[0]) : undefined;
        return { type: h.entity, id: h.id, title: h.title, icon: t?.icon ?? (e ? calendarById.get(e.calendarId)?.icon ?? 'calendar' : 'calendar'), kind: t?.kind ?? ('do' as const), color: e?.extra?.color ?? (e ? calendarById.get(e.calendarId)?.color : '') ?? 'var(--blue)', at: h.at, semantic: true };
      }),
      ...tasks.filter((t) => !sem.has(`task-${t.id}`) && (m(t.title) || m(t.notes) || m(t.category) || t.tags.some((g) => g.toLowerCase() === tag) || m(t.extra?.place?.name) || m(t.location))).map((t) => ({ type: 'task' as const, id: t.id, title: t.title, icon: t.icon, kind: t.kind, color: '', at: t.plannedStart ?? t.checkAt })),
      ...(scope === 'all' ? events.filter((e) => !sem.has(`event-${e.id}`) && (m(e.title) || m(e.notes) || m(e.extra?.place?.name) || m(e.source?.type === 'timetree' ? 'timetree' : '') || m(e.source?.calendarName))).map((e) => ({ type: 'event' as const, id: e.id, title: e.title, icon: calendarById.get(e.calendarId)?.icon ?? 'calendar', kind: 'do' as const, color: e.extra?.color ?? calendarById.get(e.calendarId)?.color ?? 'var(--blue)', at: e.start as number | null })) : []),
    ].sort((a, b) => Number(!!(b as { semantic?: boolean }).semantic) - Number(!!(a as { semantic?: boolean }).semantic) || (b.at ?? 0) - (a.at ?? 0)).slice(0, 30);
  }, [q, tasks, events, scope, calendarById]);

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
                {/* 探したものがなければ、その文章のまま追加できる（P46：検索と入力を1つの欄で） */}
                <button type="button" className="row row-button tint-row" onClick={() => { setOpen(false); openSheet({ kind: 'quickAdd', text: q }); }} data-testid="search-add"><Icon name="plus" size={18} /><span className="row-label">「{q.trim()}」を追加</span></button>
                {results.map((r) => (
                  <button key={`${r.type}-${r.id}`} type="button" role="option" aria-selected={false} className="row row-button" onClick={() => go(r)} data-testid="search-result">
                    {r.type === 'task' ? <TaskBadge icon={r.icon} kind={r.kind === 'check' ? 'check' : 'do'} size={28} /> : <EventBadge icon={r.icon} color={r.color} size={28} />}
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
