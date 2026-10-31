import { useMemo, useRef } from 'react';
import { motion, useMotionValue, useReducedMotion } from 'motion/react';
import { addDays, eventsForDay, isSameDay, startOfDay, tasksForDay } from '@my-time/domain';
import { useData, useVisibleEvents } from '../../app/data';
import { useUI } from '../../app/ui';
import { useNow } from '../../app/useNow';
import { formatMonth } from '../../app/format';
import { Icon } from '../../components/Icon';
import { MenuButton, type MenuItem } from '../../components/Menu';
import type { CalendarViewPref } from '../../data/db';
import { repo } from '../../data/repo';
import { usePager } from '../../gestures/usePager';
import { Timeline } from '../timeline/Timeline';
import { useTimelineActions } from '../timeline/useTimelineActions';

const VIEW_LABEL: Record<CalendarViewPref, string> = { day: '日', '2day': '2日', week: '週', month: '月' };

export function weekStart(t: number): number {
  const d = startOfDay(t);
  return addDays(d, -new Date(d).getDay());
}

export function CalendarScreen() {
  const { tasks, subtasksByTask, calendarById, settings } = useData();
  const events = useVisibleEvents();
  const { calDate, setCalDate, openSheet } = useUI();
  const now = useNow();
  const actions = useTimelineActions();
  const view = settings.calendarView;
  const setView = (v: CalendarViewPref) => void repo.updateSettings({ calendarView: v });

  const days = view === 'day' ? 1 : view === '2day' ? 2 : 7;
  const startDay = view === 'week' ? weekStart(calDate) : calDate;
  const step = days;

  const viewItems: MenuItem[] = (['day', '2day', 'week', 'month'] as const).map((v) => ({ label: VIEW_LABEL[v], checked: v === view, onSelect: () => setView(v) }));
  const isTodayVisible = view === 'month' ? new Date(calDate).getMonth() === new Date(now).getMonth() && new Date(calDate).getFullYear() === new Date(now).getFullYear() : now >= startDay && now < addDays(startDay, days);

  return (
    <div className="screen calendar" data-testid="calendar-screen" data-view={view}>
      <header className="nav">
        <h1 className="nav-title-left">{formatMonth(view === 'week' ? startDay : calDate)}</h1>
        <div className="nav-actions">
          <button type="button" className="nav-text-btn" disabled={isTodayVisible} onClick={() => setCalDate(Date.now())}>今日</button>
          <MenuButton label={`表示：${VIEW_LABEL[view]}`} items={viewItems} className="nav-pill-btn" testId="view-menu">
            {VIEW_LABEL[view]}
            <Icon name="chevronDown" size={14} strokeWidth={2.4} />
          </MenuButton>
          <button type="button" className="nav-icon-btn" aria-label="検索" onClick={() => openSheet({ kind: 'search' })}>
            <Icon name="search" />
          </button>
          <MenuButton label="追加" testId="cal-add" items={[
            { label: '新規予定', icon: 'calendar', onSelect: () => openSheet({ kind: 'editEvent' }) },
            { label: '新規タスク', icon: 'checklist', onSelect: () => openSheet({ kind: 'editTask' }) },
          ]}>
            <Icon name="plus" />
          </MenuButton>
        </div>
      </header>
      <div className="calendar-body">
        {view === 'month' ? (
          <MonthView month={calDate} now={now} onPick={(d) => { setCalDate(d); setView('day'); }} onPage={(dir) => { const d = new Date(calDate); d.setDate(1); d.setMonth(d.getMonth() + dir); setCalDate(d.getTime()); }} />
        ) : (
          <Timeline
            testId="cal-timeline"
            startDay={startDay}
            days={days}
            now={now}
            events={events}
            tasks={tasks.filter((t) => t.kind === 'do')}
            subtasksByTask={subtasksByTask}
            calendarById={calendarById}
            dayLabels="all"
            onPage={(dir) => setCalDate(addDays(calDate, dir * step))}
            onTapDay={(d) => { setCalDate(d); if (view !== 'day') setView('day'); }}
            {...actions}
          />
        )}
      </div>
    </div>
  );
}

function MonthView({ month, now, onPick, onPage }: { month: number; now: number; onPick: (d: number) => void; onPage: (dir: 1 | -1) => void }) {
  const { tasks, calendarById } = useData();
  const events = useVisibleEvents();
  const reduce = useReducedMotion() ?? false;
  const x = useMotionValue(0);
  const ref = useRef<HTMLDivElement>(null);
  usePager(ref, { x, onPage, reduceMotion: reduce });

  const first = new Date(month);
  first.setDate(1);
  const firstDay = startOfDay(first.getTime());
  const gridStart = weekStart(firstDay);
  const cells = useMemo(() => Array.from({ length: 42 }, (_, i) => addDays(gridStart, i)), [gridStart]);
  const m = first.getMonth();

  return (
    <div className="month" ref={ref} data-testid="month-view">
      <div className="month-weekdays" aria-hidden>
        {['日', '月', '火', '水', '木', '金', '土'].map((w) => (
          <span key={w}>{w}</span>
        ))}
      </div>
      <motion.div className="month-grid" style={{ x }} role="grid" aria-label={formatMonth(firstDay)}>
        {cells.map((d) => {
          const evs = eventsForDay(events, d);
          const ts = tasksForDay(tasks, d);
          const items = [...evs.map((e) => ({ id: e.id, title: e.title, color: calendarById.get(e.calendarId)?.color ?? 'var(--blue)' })), ...ts.map((t) => ({ id: t.id, title: `${t.icon}${t.title}`, color: 'var(--blue)' }))];
          const inMonth = new Date(d).getMonth() === m;
          return (
            <button key={d} type="button" role="gridcell" className={`month-cell ${inMonth ? '' : 'out'} ${isSameDay(d, now) ? 'today' : ''}`} onClick={() => onPick(d)} aria-label={`${new Date(d).getMonth() + 1}月${new Date(d).getDate()}日 ${items.length}件`} data-testid={`month-cell-${new Date(d).getDate()}-${inMonth ? 'in' : 'out'}`}>
              <span className="month-num">{new Date(d).getDate()}</span>
              <span className="month-items">
                {items.slice(0, 3).map((it) => (
                  <span key={it.id} className="month-item" style={{ ['--c' as string]: it.color }}>{it.title}</span>
                ))}
                {items.length > 3 && <span className="month-more">+{items.length - 3}</span>}
              </span>
            </button>
          );
        })}
      </motion.div>
    </div>
  );
}
