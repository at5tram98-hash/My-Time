import { useMemo, useState } from 'react';
import { motion, AnimatePresence, useReducedMotion } from 'motion/react';
import {
  addDays, busyItems, detectIssues, expandAll, formatDayLabel, formatHm, freeTime, idealProgress, isSameDay, isUnscheduled, nextAction, startOfDay, tasksForDay, workedMs,
  type Subtask, type Task,
} from '@my-time/domain';
import { useData, useVisibleEvents } from '../../app/data';
import { useUIActions, useUIDates } from '../../app/ui';
import { InlineSearch } from '../search/InlineSearch';
import { useNow } from '../../app/useNow';
import { Icon, type IconName } from '../../components/Icon';
import { MenuButton, type MenuItem } from '../../components/Menu';
import { repo } from '../../data/repo';
import { Timeline } from '../timeline/Timeline';
import { useTimelineActions } from '../timeline/useTimelineActions';
import { DatePickerPopup } from '../editor/pickers';
import { SettingsButton } from '../other/SettingsButton';
import { Ring } from '../../ui/Ring';
import { progressOf } from '../../app/progress';
import { SPRING } from '../../ui/motion';
import { orderHomeTasks } from './homeOrder';

const LANE_PCT = { both: 52, main: 68, detail: 34 } as const;
const elapsed = (ms: number) => { const m = Math.floor(ms / 60_000); return m >= 60 ? `${Math.floor(m / 60)}時間${m % 60}分` : `${m}分`; };

/**
 * 今日（1日だけの画面：P21・IOS-001〜010）。
 * - 上：今やること（1枚のカード）と、注意・未割当・タスク・余白の小さな要約。タップで詳しい画面を開く。
 * - 下：共通の時刻軸に、左＝時間の決まった予定（授業・勤務・外出）、右＝細かな行動（タスク・作業枠・確認）。
 * - 横スワイプで日付を変える。レーンの見出しをタップすると、そのレーンを広く表示する。
 */
export function HomeScreen() {
  const { tasks, events: allEvents, subtasksByTask, calendarById, settings, studioTypes } = useData();
  const { homeDate } = useUIDates();
  const { setHomeDate, openSheet, setTab, setCalDate } = useUIActions();
  const now = useNow();
  const reduce = useReducedMotion() ?? false;
  const actions = useTimelineActions();
  const [datePick, setDatePick] = useState(false);
  const day = homeDate;
  const isToday = isSameDay(day, now);
  const events = useVisibleEvents(addDays(day, -1), addDays(day, 2), now);
  const allSubs = useMemo(() => [...subtasksByTask.values()].flat(), [subtasksByTask]);

  const dayTasks = useMemo(() => orderHomeTasks(tasksForDay(tasks, day), now), [tasks, day, now]);
  const doneCount = dayTasks.filter((t) => t.status === 'done' || t.checked).length;
  const visibleTasks = useMemo(() => {
    const end = addDays(day, 1);
    return tasks.filter((t) => t.kind === 'do' && t.plannedStart != null && t.plannedStart < end && (t.plannedEnd ?? t.plannedStart) > day - 86_400_000);
  }, [tasks, day]);
  const taskById = useMemo(() => new Map(tasks.map((t) => [t.id, t])), [tasks]);
  const lanes = useMemo(() => {
    const d1 = addDays(day, 1);
    const sessions: { sub: Subtask; task: Task }[] = [];
    for (const s of allSubs) {
      if (s.plannedStart == null || s.plannedEnd == null || s.plannedStart >= d1 || s.plannedEnd <= day) continue;
      const t = taskById.get(s.taskId);
      if (t) sessions.push({ sub: s, task: t });
    }
    const checks = tasks.filter((t) => t.kind === 'check' && t.checkAt != null && t.checkAt >= day && t.checkAt < d1);
    const linkColor = new Map<string, string>();
    for (const t of tasks) {
      if (!t.sourceEventId) continue;
      const ev = allEvents.find((e) => e.id === t.sourceEventId);
      if (ev) linkColor.set(t.id, ev.extra?.color ?? calendarById.get(ev.calendarId)?.color ?? 'var(--blue)');
    }
    return { mainPct: LANE_PCT[settings.laneFocus], sessions, checks, linkColor };
  }, [allSubs, taskById, tasks, day, allEvents, calendarById, settings.laneFocus]);

  // 注意（今日〜明日）と未割当・余白
  const issues = useMemo(() => {
    const evs = expandAll(allEvents, day - 86_400_000, addDays(day, 3));
    return detectIssues({ events: evs, tasks, subtasks: allSubs, now, from: day, to: addDays(day, 1), opts: { fromHour: settings.suggestFromHour, toHour: settings.suggestToHour, stepMin: settings.suggestStepMin } });
  }, [allEvents, tasks, allSubs, now, day, settings.suggestFromHour, settings.suggestToHour, settings.suggestStepMin]);
  const inbox = useMemo(() => tasks.filter((t) => t.kind === 'do' && t.status !== 'done' && isUnscheduled(t) && !(subtasksByTask.get(t.id) ?? []).some((s) => s.plannedStart != null && !s.done)).length, [tasks, subtasksByTask]);
  const free = useMemo(() => freeTime(day, busyItems(events, tasks, allSubs), { fromHour: settings.suggestFromHour, toHour: settings.suggestToHour, stepMin: 15 }), [day, events, tasks, allSubs, settings.suggestFromHour, settings.suggestToHour]);
  const next = useMemo(() => nextAction(events, tasks, now), [events, tasks, now]);
  const alertCount = issues.filter((i) => i.severity !== 'info').length;

  const goCalendar = () => { setCalDate(day); void repo.updateSettings({ calendarView: 'day' }); setTab('calendar'); };
  const moreItems: (MenuItem | 'separator')[] = [
    { label: '今日へ移動', icon: 'today', disabled: isToday, onSelect: () => setHomeDate(startOfDay(Date.now())) },
    { label: '日付を選択', icon: 'calendar', onSelect: () => setDatePick(true) },
    { label: 'カレンダーで表示', icon: 'calendar', onSelect: goCalendar },
    { label: '1日の振り返り', icon: 'history', onSelect: () => openSheet({ kind: 'review', day }) },
    'separator',
    { label: '予定とタスクを同じ幅で', icon: 'lanes', checked: settings.laneFocus === 'both', onSelect: () => void repo.updateSettings({ laneFocus: 'both' }) },
    { label: '予定を広く', icon: 'calendar', checked: settings.laneFocus === 'main', onSelect: () => void repo.updateSettings({ laneFocus: 'main' }) },
    { label: 'タスクを広く', icon: 'checklist', checked: settings.laneFocus === 'detail', onSelect: () => void repo.updateSettings({ laneFocus: 'detail' }) },
  ];
  const hd = new Date(day);
  const focus = (l: 'main' | 'detail') => void repo.updateSettings({ laneFocus: settings.laneFocus === l ? 'both' : l });
  const dayEvents = events.filter((e) => e.start < addDays(day, 1) && e.end > day && !e.extra?.allDay);
  const collapsed = settings.todaySummaryCollapsed;

  return (
    <div className="screen home today" data-testid="home-screen" data-lane-focus={settings.laneFocus}>
      <header className="nav home-nav">
        <button type="button" className="date-head" onClick={() => !isToday && setHomeDate(startOfDay(Date.now()))} aria-label={`${formatDayLabel(day)}${isToday ? '（今日）' : '。タップで今日へ'}`} data-testid="home-date">
          <span className="date-month">{hd.getFullYear()}年{hd.getMonth() + 1}月</span>
          <span className="date-main">
            <span className={`date-day ${isToday ? 'today' : ''}`}>{hd.getDate()}日</span>
            <span className="date-wd">{'日月火水木金土'[hd.getDay()]}曜日</span>
            {!isToday && <span className="nav-date-today">今日へ</span>}
          </span>
        </button>
        <div className="nav-actions gap">
          <InlineSearch target="home" />
          <MenuButton label="その他の操作" items={moreItems} className="gbtn glass glass-i" testId="home-more">
            <Icon name="more" size={20} strokeWidth={3} />
          </MenuButton>
          <SettingsButton />
        </div>
      </header>

      {/* 要約：今やること → 注意・未割当・タスク・余白（概要 → 詳細の順に1回のタップで開く：IOS-002・IOS-003） */}
      <section className={`today-summary ${collapsed ? 'collapsed' : ''}`} aria-label="今日の要約" data-testid="today-summary">
        <AnimatePresence initial={false}>
          {!collapsed && (
            <motion.div key="now" initial={reduce ? { opacity: 0 } : { opacity: 0, height: 0 }} animate={reduce ? { opacity: 1 } : { opacity: 1, height: 'auto' }} exit={reduce ? { opacity: 0 } : { opacity: 0, height: 0 }} transition={reduce ? { duration: 0.12 } : SPRING.sheet} style={{ overflow: 'hidden' }}>
              <NowCard next={next} tasks={tasks} subtasksByTask={subtasksByTask} studioTypes={studioTypes} now={now} isToday={isToday} />
            </motion.div>
          )}
        </AnimatePresence>
        <div className="today-chips" role="group" aria-label="今日の状況">
          <Chip icon="warning" tone={alertCount ? 'warn' : 'quiet'} label="注意" value={issues.length ? `${issues.length}` : 'なし'} onClick={() => openSheet({ kind: 'issues', day })} testId="chip-issues" />
          <Chip icon="inbox" tone={inbox ? 'tint' : 'quiet'} label="未割当" value={`${inbox}`} onClick={() => openSheet({ kind: 'inbox' })} testId="chip-inbox" />
          <Chip icon="checklist" tone="quiet" label={isToday ? '今日のタスク' : 'タスク'} value={dayTasks.length ? `${doneCount}/${dayTasks.length}` : '0'} onClick={() => openSheet({ kind: 'dayTasks', day })} testId="chip-tasks" />
          <Chip icon="sun" tone="quiet" label="余白" value={`${Math.round(free.ratio * 100)}%`} onClick={() => openSheet({ kind: 'review', day })} testId="chip-free" />
          <button type="button" className="today-collapse" aria-label={collapsed ? '要約を広げる' : '要約をたたむ'} aria-expanded={!collapsed} onClick={() => void repo.updateSettings({ todaySummaryCollapsed: !collapsed })} data-testid="summary-toggle">
            <Icon name="chevronDown" size={16} strokeWidth={2.6} style={{ transform: collapsed ? 'rotate(0deg)' : 'rotate(180deg)', transition: 'transform 240ms var(--spring)' }} />
          </button>
        </div>
      </section>

      {/* レーンの見出し（タップでそのレーンを広く：IOS-006） */}
      <div className="lane-head" style={{ ['--main' as string]: `${lanes.mainPct}%` }}>
        <span className="lane-gutter" aria-hidden />
        <button type="button" className={`lane-label main ${settings.laneFocus === 'main' ? 'on' : ''}`} onClick={() => focus('main')} aria-pressed={settings.laneFocus === 'main'} data-testid="lane-main">
          <Icon name="calendar" size={14} strokeWidth={2.3} />予定<span className="lane-count">{dayEvents.length}</span>
        </button>
        <button type="button" className={`lane-label detail ${settings.laneFocus === 'detail' ? 'on' : ''}`} onClick={() => focus('detail')} aria-pressed={settings.laneFocus === 'detail'} data-testid="lane-detail">
          <Icon name="checklist" size={14} strokeWidth={2.3} />タスク<span className="lane-count">{dayTasks.length + lanes.sessions.length}</span>
        </button>
      </div>
      <div className="home-timeline">
        <Timeline
          testId="home-timeline"
          startDay={day}
          days={1}
          now={now}
          events={events}
          tasks={visibleTasks}
          subtasksByTask={subtasksByTask}
          calendarById={calendarById}
          dayLabels="none"
          lanes={lanes}
          onPage={(dir) => setHomeDate(addDays(day, dir))}
          {...actions}
        />
      </div>
      <DatePickerPopup open={datePick} value={day} title="日付を選択" onClose={() => setDatePick(false)} onPick={(d) => { setDatePick(false); setHomeDate(d); }} />
    </div>
  );
}

function Chip({ icon, label, value, tone, onClick, testId }: { icon: IconName; label: string; value: string; tone: 'warn' | 'tint' | 'quiet'; onClick: () => void; testId: string }) {
  return (
    <button type="button" className={`today-chip ${tone}`} onClick={onClick} data-testid={testId} aria-label={`${label} ${value}`}>
      <Icon name={icon} size={15} strokeWidth={2.3} />
      <span className="chip-label">{label}</span>
      <span className="chip-value">{value}</span>
    </button>
  );
}

/** 今やること（P24）。実行中なら進捗と操作、そうでなければ次の1件だけ */
function NowCard({ next, tasks, subtasksByTask, studioTypes, now, isToday }: { next: ReturnType<typeof nextAction>; tasks: Task[]; subtasksByTask: Map<string, Subtask[]>; studioTypes: ReturnType<typeof useData>['studioTypes']; now: number; isToday: boolean }) {
  const { openSheet, showToast } = useUIActions();
  const task = next.ref?.entity === 'task' ? tasks.find((t) => t.id === next.ref!.id) : undefined;
  const open = () => { if (next.ref) openSheet({ kind: 'info', entity: next.ref.entity, id: next.ref.id }); else openSheet({ kind: 'quickAdd' }); };
  const act = async (a: 'start' | 'pause' | 'finish') => {
    if (!task) return;
    try { await repo.taskAction(task.id, a); showToast(a === 'start' ? '開始しました' : a === 'pause' ? '停止しました' : '完了しました'); } catch (e) { showToast(e instanceof Error ? e.message : '操作できませんでした'); }
  };
  const label = { continue: '実行中', start: '次にやること', leave: '出発', event: '予定の最中', plan: '時間を決める', free: isToday ? 'この後' : 'この日' }[next.kind];
  const pr = task ? progressOf(task, subtasksByTask.get(task.id) ?? [], studioTypes, now) : null;
  return (
    <div className={`now-card ${next.kind}`} data-testid="now-card" data-kind={next.kind}>
      <button type="button" className="now-main" onClick={open} aria-label={`${label}：${next.title}、${next.detail}。タップで詳細`}>
        {task ? <Ring value={pr?.value ?? null} ideal={idealProgress(task, now)} size={40} icon={task.icon} kind="do" running={task.status === 'running'} /> : <span className={`now-ico ${next.kind}`} aria-hidden><Icon name={next.kind === 'leave' ? 'train' : next.kind === 'event' ? 'calendar' : next.kind === 'free' ? 'sun' : 'clock'} size={20} strokeWidth={2.2} /></span>}
        <span className="now-text">
          <span className="now-label">{label}</span>
          <span className="now-title" data-user-text>{next.title}</span>
          <span className="now-detail">{task?.status === 'running' ? `${elapsed(workedMs(task, now))}${pr?.value != null ? `・実績${Math.round(pr.value * 100)}%` : ''}` : next.detail}{next.at != null && next.kind !== 'continue' && next.at > now ? `（${formatHm(next.at)}）` : ''}</span>
        </span>
      </button>
      <div className="now-actions">
        {task?.status === 'running' && <><button type="button" className="now-btn" onClick={() => void act('pause')} aria-label="停止" data-testid="now-pause"><Icon name="pause" size={18} strokeWidth={2.4} /></button><button type="button" className="now-btn green" onClick={() => void act('finish')} aria-label="完了" data-testid="now-finish"><Icon name="check" size={18} strokeWidth={2.6} /></button></>}
        {task && next.kind === 'start' && <button type="button" className="now-btn tint" onClick={() => void act('start')} aria-label="開始" data-testid="now-start"><Icon name="play" size={18} strokeWidth={2.4} /></button>}
        {next.kind === 'plan' && <button type="button" className="now-btn tint" onClick={() => openSheet({ kind: 'inbox' })} aria-label="未割当を開く" data-testid="now-plan"><Icon name="inbox" size={18} strokeWidth={2.2} /></button>}
        {next.kind === 'free' && <button type="button" className="now-btn tint" onClick={() => openSheet({ kind: 'quickAdd' })} aria-label="追加" data-testid="now-add"><Icon name="plus" size={18} strokeWidth={2.4} /></button>}
      </div>
    </div>
  );
}
