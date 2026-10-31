import { useEffect, useLayoutEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent } from 'react';
import { animate, motion, useMotionValue, useMotionValueEvent, useReducedMotion, useTransform } from 'motion/react';
import { addDays, formatDayLabel, isSameDay, runningAndNext, startOfDay, tasksForDay } from '@my-time/domain';
import { useData, useVisibleEvents } from '../../app/data';
import { useUI } from '../../app/ui';
import { useNow } from '../../app/useNow';
import { Icon } from '../../components/Icon';
import { MenuButton, type MenuItem } from '../../components/Menu';
import { repo } from '../../data/repo';
import { gestureLock } from '../../gestures/gestureLock';
import { usePager } from '../../gestures/usePager';
import { TaskRow } from '../tasks/TaskRow';
import { Timeline } from '../timeline/Timeline';
import { useTimelineActions } from '../timeline/useTimelineActions';
import { FloatingCards, CARDS_H } from './FloatingCards';

const HANDLE_H = 22;
const SPRING = { type: 'spring', stiffness: 380, damping: 38, mass: 0.9 } as const;

export function HomeScreen() {
  const { tasks, subtasksByTask, calendarById, settings } = useData();
  const events = useVisibleEvents();
  const { homeDate, setHomeDate, openSheet } = useUI();
  const now = useNow();
  const reduce = useReducedMotion() ?? false;
  const actions = useTimelineActions();

  const bodyRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const [bodyH, setBodyH] = useState(600);
  const [navW, setNavW] = useState(390);
  const [expanded, setExpanded] = useState(false);
  const expandedRef = useRef(false);
  const paneH = useMotionValue(0);
  const handleDrag = useRef<{ y: number; h: number; id: number; moved: boolean; samples: { y: number; t: number }[] } | null>(null);
  const listX = useMotionValue(0);

  // 通常状態のタスク領域は利用可能高さの約38%（35〜42%の範囲）
  const normalH = Math.round(Math.min(Math.max(bodyH * 0.38, 168), bodyH - 220));
  // 拡張時に残すカードがないときは帯そのものを出さない（空のカードは表示しない）
  const { running, next } = useMemo(() => runningAndNext(tasks, now), [tasks, now]);
  const collapsedH = running.length > 0 || next ? CARDS_H : 0;

  useLayoutEffect(() => {
    const el = bodyRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      setBodyH(el.clientHeight);
      setNavW(el.clientWidth);
    });
    ro.observe(el);
    setBodyH(el.clientHeight);
    setNavW(el.clientWidth);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    // サイズ変更時は現在の状態の高さへ追従
    if (!handleDrag.current) paneH.set(expandedRef.current ? collapsedH : normalH);
  }, [normalH, collapsedH, paneH]);

  const listOpacity = useTransform(paneH, [collapsedH + 24, normalH * 0.75], [0, 1]);
  const cardsOpacity = useTransform(paneH, [collapsedH, collapsedH + 70], [1, 0]);
  const [cardsInteractive, setCardsInteractive] = useState(false);
  useMotionValueEvent(paneH, 'change', (v) => setCardsInteractive(v < collapsedH + 30));

  const settle = (toExpanded: boolean) => {
    expandedRef.current = toExpanded;
    setExpanded(toExpanded);
    const target = toExpanded ? collapsedH : normalH;
    if (reduce) paneH.set(target);
    else void animate(paneH, target, SPRING);
  };

  // ---- 境界ハンドル：縦ドラッグのみで切替（タップでは拡張しない） ----
  
  const onHandleDown = (e: RPointerEvent<HTMLDivElement>) => {
    if (e.button !== 0 || !gestureLock.acquire('split')) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    handleDrag.current = { y: e.clientY, h: paneH.get(), id: e.pointerId, moved: false, samples: [{ y: e.clientY, t: performance.now() }] };
    paneH.stop();
  };
  const onHandleMove = (e: RPointerEvent<HTMLDivElement>) => {
    const d = handleDrag.current;
    if (!d || d.id !== e.pointerId) return;
    const dy = e.clientY - d.y;
    if (Math.abs(dy) > 3) d.moved = true;
    d.samples.push({ y: e.clientY, t: performance.now() });
    if (d.samples.length > 6) d.samples.shift();
    let h = d.h + dy;
    // 範囲外はゴムのように抵抗
    if (h < collapsedH) h = collapsedH - Math.sqrt(collapsedH - h) * 2;
    if (h > normalH) h = normalH + Math.sqrt(h - normalH) * 3;
    paneH.set(h);
  };
  const onHandleUp = (e: RPointerEvent<HTMLDivElement>) => {
    const d = handleDrag.current;
    handleDrag.current = null;
    gestureLock.release('split');
    if (!d || d.id !== e.pointerId) return;
    if (!d.moved) {
      settle(expandedRef.current); // タップは何もしない（元の状態に戻すだけ）
      return;
    }
    // 指を離す直前（約100ms）の速度で判定し、遅ければ位置で判定
    const nowT = performance.now();
    const recent = d.samples.filter((p) => nowT - p.t < 100);
    const first = recent[0] ?? d.samples[0]!;
    const v = (e.clientY - first.y) / Math.max(16, nowT - first.t); // px/ms（負＝上方向）
    const h = paneH.get();
    let toExpanded: boolean;
    if (v < -0.35) toExpanded = true;
    else if (v > 0.35) toExpanded = false;
    else toExpanded = h < (collapsedH + normalH) / 2;
    settle(toExpanded);
  };
  /** pointercancel（OSのジェスチャー・着信など）では開閉を確定せず、元の状態へ戻す */
  const onHandleCancel = (e: RPointerEvent<HTMLDivElement>) => {
    const d = handleDrag.current;
    handleDrag.current = null;
    gestureLock.release('split');
    if (d && d.id === e.pointerId) settle(expandedRef.current);
  };

  const days = expanded ? Math.min(7, Math.max(1, settings.expandedDays)) : settings.homeDays;
  const dayTasks = useMemo(() => tasksForDay(tasks, homeDate), [tasks, homeDate]);
  const doneCount = dayTasks.filter((t) => t.status === 'done').length;
  const isToday = isSameDay(homeDate, now);
  const visibleTasks = useMemo(() => {
    const end = addDays(homeDate, days);
    return tasks.filter((t) => t.kind === 'do' && t.plannedStart != null && t.plannedStart < end && (t.plannedEnd ?? t.plannedStart) > homeDate - 86_400_000);
  }, [tasks, homeDate, days]);

  usePager(listRef, { x: listX, onPage: (dir) => setHomeDate(addDays(homeDate, dir)), reduceMotion: reduce });

  const narrow = navW < 360;
  const addItems: MenuItem[] = [
    { label: '新規タスク', icon: 'checklist', onSelect: () => openSheet({ kind: 'editTask' }) },
    { label: '新規予定', icon: 'calendar', onSelect: () => openSheet({ kind: 'editEvent' }) },
  ];
  const moreItems: (MenuItem | 'separator')[] = [
    ...(narrow ? [{ label: '検索', icon: 'search' as const, onSelect: () => openSheet({ kind: 'search' }) }] : []),
    { label: '今日へ移動', icon: 'today', disabled: isToday, onSelect: () => setHomeDate(startOfDay(Date.now())) },
    { label: expanded ? 'タスク一覧を戻す' : 'カレンダーを広げる', icon: 'expand', onSelect: () => settle(!expanded) },
  ];
  const dayMenu: MenuItem[] = Array.from({ length: 7 }, (_, i) => ({
    label: `${i + 1}日`,
    checked: settings.expandedDays === i + 1,
    onSelect: () => void repo.updateSettings({ expandedDays: i + 1 }),
  }));

  return (
    <div className="screen home" data-testid="home-screen" data-expanded={expanded}>
      <header className="nav home-nav">
        <button type="button" className="nav-date" onClick={() => !isToday && setHomeDate(startOfDay(Date.now()))} aria-label={`${formatDayLabel(homeDate)}${isToday ? '（今日）' : '。タップで今日へ'}`} data-testid="home-date">
          {formatDayLabel(homeDate)}
          {!isToday && <span className="nav-date-today">今日</span>}
        </button>
        <div className="nav-actions">
          {expanded ? (
            <MenuButton label={`表示日数（${days}日）`} items={dayMenu} testId="days-toggle">
              <Icon name="daysN" />
              <span className="nav-badge-num">{days}</span>
            </MenuButton>
          ) : (
            <button type="button" className="nav-icon-btn" aria-label={settings.homeDays === 1 ? '2日表示に切り替え' : '1日表示に切り替え'} data-testid="days-toggle" data-days={settings.homeDays} onClick={() => void repo.updateSettings({ homeDays: settings.homeDays === 1 ? 2 : 1 })}>
              <Icon name={settings.homeDays === 1 ? 'days1' : 'days2'} />
            </button>
          )}
          {!narrow && (
            <button type="button" className="nav-icon-btn" aria-label="検索" onClick={() => openSheet({ kind: 'search' })}>
              <Icon name="search" />
            </button>
          )}
          <MenuButton label="追加" items={addItems} testId="home-add">
            <Icon name="plus" />
          </MenuButton>
          <MenuButton label="その他の操作" items={moreItems}>
            <Icon name="more" strokeWidth={3} />
          </MenuButton>
        </div>
      </header>

      <div className="home-body" ref={bodyRef}>
        <motion.section className="task-pane" style={{ height: paneH }} aria-label="タスク一覧" data-testid="task-pane">
          <motion.div className="task-list-wrap" style={{ opacity: listOpacity, pointerEvents: cardsInteractive ? 'none' : 'auto' }} aria-hidden={cardsInteractive}>
            <div className="task-list" ref={listRef} data-testid="home-task-list">
              <motion.div style={{ x: listX }}>
                <div className="list-heading">
                  <span>{isToday ? '今日のタスク' : `${formatDayLabel(homeDate)}のタスク`}</span>
                  {dayTasks.length > 0 && <span className="list-count">{doneCount}/{dayTasks.length}</span>}
                </div>
                {dayTasks.length === 0 ? (
                  <div className="empty-list">
                    <p>時間が指定されたタスクはありません</p>
                    <button type="button" className="link-btn" onClick={() => openSheet({ kind: 'editTask' })}>タスクを追加</button>
                  </div>
                ) : (
                  <div className="rows">
                    {dayTasks.map((t) => (
                      <TaskRow key={t.id} task={t} subtasks={subtasksByTask.get(t.id) ?? []} now={now} />
                    ))}
                  </div>
                )}
              </motion.div>
            </div>
          </motion.div>
          <motion.div className="cards-wrap" style={{ opacity: cardsOpacity, pointerEvents: cardsInteractive ? 'auto' : 'none' }} aria-hidden={!cardsInteractive}>
            <FloatingCards tasks={tasks} subtasksByTask={subtasksByTask} now={now} />
          </motion.div>
        </motion.section>

        <div
          className="split-handle"
          role="separator"
          aria-orientation="horizontal"
          aria-label="タスクとカレンダーの境界。上下にドラッグして表示を切り替え"
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={expanded ? 100 : 0}
          tabIndex={0}
          style={{ height: HANDLE_H }}
          data-testid="split-handle"
          onPointerDown={onHandleDown}
          onPointerMove={onHandleMove}
          onPointerUp={onHandleUp}
          onPointerCancel={onHandleCancel}
          onKeyDown={(e) => {
            if (e.key === 'ArrowUp') settle(true);
            if (e.key === 'ArrowDown') settle(false);
          }}
        >
          <span className="split-grip" />
        </div>

        <div className="home-timeline">
          <Timeline
            testId="home-timeline"
            startDay={homeDate}
            days={days}
            now={now}
            events={events}
            tasks={visibleTasks}
            subtasksByTask={subtasksByTask}
            calendarById={calendarById}
            dayLabels="afterFirst"
            onPage={(dir) => setHomeDate(addDays(homeDate, dir))}
            {...actions}
          />
        </div>
      </div>
    </div>
  );
}
