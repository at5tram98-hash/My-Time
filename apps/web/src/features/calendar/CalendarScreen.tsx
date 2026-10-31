import { useMemo, useRef } from 'react';
import { motion, useMotionValue, useReducedMotion } from 'motion/react';
import { addDays, eventsForDay, isMultiDay, isSameDay, layoutWeekBars, startOfDay, tasksForDay } from '@my-time/domain';
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

const ROW_H = 17; // 1段の高さ(px)
const MAX_ROWS = 4; // 1日に表示する段数（超えた分は +N）

/**
 * 月表示。日付をまたぐ予定は週の中で途切れない1本のバーとして描き、週をまたぐときは端を角張らせて「続き」を示す。
 */
function MonthView({ month, now, onPick, onPage }: { month: number; now: number; onPick: (d: number) => void; onPage: (dir: 1 | -1) => void }) {
  const reduce = useReducedMotion() ?? false;
  const x = useMotionValue(0);
  const ref = useRef<HTMLDivElement>(null);
  usePager(ref, { x, onPage, reduceMotion: reduce });

  const first = new Date(month);
  first.setDate(1);
  const firstDay = startOfDay(first.getTime());
  const gridStart = weekStart(firstDay);
  const weeks = useMemo(() => Array.from({ length: 6 }, (_, i) => addDays(gridStart, i * 7)), [gridStart]);

  return (
    <div className="month" ref={ref} data-testid="month-view">
      <div className="month-weekdays" aria-hidden>
        {['日', '月', '火', '水', '木', '金', '土'].map((w) => (
          <span key={w}>{w}</span>
        ))}
      </div>
      <motion.div className="month-weeks" style={{ x }} role="grid" aria-label={formatMonth(firstDay)}>
        {weeks.map((ws) => (
          <MonthWeek key={ws} weekStart={ws} month={first.getMonth()} now={now} onPick={onPick} />
        ))}
      </motion.div>
    </div>
  );
}

function MonthWeek({ weekStart: ws, month, now, onPick }: { weekStart: number; month: number; now: number; onPick: (d: number) => void }) {
  const { tasks, calendarById } = useData();
  const events = useVisibleEvents();
  const days = Array.from({ length: 7 }, (_, i) => addDays(ws, i));
  const colorOf = (calId: string) => calendarById.get(calId)?.color ?? 'var(--blue)';
  const bars = layoutWeekBars(events, ws);
  const lanesAt = (col: number) => bars.filter((b) => col >= b.col && col < b.col + b.span).reduce((m, b) => Math.max(m, b.lane + 1), 0);

  return (
    <div className="month-week" role="row">
      {days.map((d, i) => {
        const singles = [
          ...eventsForDay(events, d).filter((e) => !isMultiDay(e)).map((e) => ({ id: `e-${e.id}`, title: e.title, color: colorOf(e.calendarId) })),
          ...tasksForDay(tasks, d).map((t) => ({ id: `t-${t.id}`, title: `${t.icon}${t.title}`, color: 'var(--blue)' })),
        ];
        const used = lanesAt(i);
        const room = Math.max(0, MAX_ROWS - used);
        const shown = singles.length > room ? singles.slice(0, Math.max(0, room - 1)) : singles;
        const hidden = singles.length - shown.length + bars.filter((b) => b.lane >= MAX_ROWS && i >= b.col && i < b.col + b.span).length;
        const total = singles.length + bars.filter((b) => i >= b.col && i < b.col + b.span).length;
        const inMonth = new Date(d).getMonth() === month;
        return (
          <button
            key={d}
            type="button"
            role="gridcell"
            className={`month-cell ${inMonth ? '' : 'out'} ${isSameDay(d, now) ? 'today' : ''}`}
            style={{ gridColumn: i + 1 }}
            onClick={() => onPick(d)}
            aria-label={`${new Date(d).getMonth() + 1}月${new Date(d).getDate()}日 ${total}件`}
            data-testid={`month-cell-${new Date(d).getDate()}-${inMonth ? 'in' : 'out'}`}
          >
            <span className="month-num">{new Date(d).getDate()}</span>
            <span className="month-items" style={{ paddingTop: Math.min(used, MAX_ROWS) * ROW_H }}>
              {shown.map((it) => (
                <span key={it.id} className="month-item" style={{ ['--c' as string]: it.color }}>{it.title}</span>
              ))}
              {hidden > 0 && <span className="month-more">+{hidden}</span>}
            </span>
          </button>
        );
      })}
      <div className="month-bars" aria-hidden>
        {bars
          .filter((b) => b.lane < MAX_ROWS)
          .map((b) => (
            <span
              key={`${b.item.id}-${ws}`}
              className={`month-bar ${b.continuesBefore ? 'cont-before' : ''} ${b.continuesAfter ? 'cont-after' : ''}`}
              style={{ left: `calc(${(b.col / 7) * 100}% + ${b.continuesBefore ? 0 : 2}px)`, width: `calc(${(b.span / 7) * 100}% - ${(b.continuesBefore ? 0 : 2) + (b.continuesAfter ? 0 : 2)}px)`, top: b.lane * ROW_H, ['--c' as string]: colorOf(b.item.calendarId) }}
              data-testid={`month-bar-${b.item.id}`}
              data-col={b.col}
              data-span={b.span}
            >
              {b.item.title}
            </span>
          ))}
      </div>
    </div>
  );
}
