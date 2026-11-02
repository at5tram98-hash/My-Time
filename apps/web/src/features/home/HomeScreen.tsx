import { useEffect, useLayoutEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent } from 'react';
import { animate, motion, useMotionValue, useMotionValueEvent, useReducedMotion, useTransform } from 'motion/react';
import { addDays, formatDayLabel, isSameDay, startOfDay, tasksForDay } from '@my-time/domain';
import { useData, useVisibleEvents } from '../../app/data';
import { useUIActions, useUIDates } from '../../app/ui';
import { InlineSearch } from '../search/InlineSearch';
import { useNow } from '../../app/useNow';
import { Icon } from '../../components/Icon';
import { MenuButton, type MenuItem } from '../../components/Menu';
import { repo } from '../../data/repo';
import { gestureLock } from '../../gestures/gestureLock';
import { usePager } from '../../gestures/usePager';
import { TaskRow } from '../tasks/TaskRow';
import { Timeline } from '../timeline/Timeline';
import { useTimelineActions } from '../timeline/useTimelineActions';
import { FloatingCards, CARDS_H, islandOrder } from './FloatingCards';
import { DatePickerPopup } from '../editor/pickers';

const HANDLE_H = 22;
const SPRING = { type: 'spring', stiffness: 380, damping: 38, mass: 0.9 } as const;

export function HomeScreen() {
  const { tasks, subtasksByTask, calendarById, settings } = useData();
  const { homeDate } = useUIDates();
  const { setHomeDate, openSheet, setTab, setCalDate } = useUIActions();
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
  // 分割比率は指を離した位置をそのまま保存（Q14）。最小・最大の安全範囲だけ設ける
  const MIN_LIST = 132;
  const maxH = Math.max(MIN_LIST, bodyH - 170); // カレンダーの最低限の高さ（Q16）
  const normalH = Math.round(Math.min(maxH, Math.max(MIN_LIST, bodyH * settings.homeSplit)));
  // 拡張時に残すカードがないときは帯そのものを出さない（空のカードは表示しない）
  const island = useMemo(() => islandOrder(tasks, now), [tasks, now]);
  // コンパクト表示は円だけ。対象がなければ空の帯を出さず高さ0（C01）
  const collapsedH = island.length ? CARDS_H : 0;
  const [datePick, setDatePick] = useState(false);

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
  useMotionValueEvent(paneH, 'change', (v) => { setCardsInteractive(v < collapsedH + 30); setDensity(v < 230 ? 's' : v < 400 ? 'm' : 'l'); });
  // パネルの高さに応じて情報量を段階的に変える（文字を縮めるのではなく項目を省く：Q08・Q17）
  const [density, setDensity] = useState<'s' | 'm' | 'l'>('m');

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
    if (h > maxH) h = maxH + Math.sqrt(h - maxH) * 3;
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
    // 小さくするとコンパクト表示（円だけ）へ。カレンダーへの移動はコンパクト表示から始めた上スワイプだけ（1回の操作で2段階進めない：C01）。それ以外は離した位置を保持して保存
    if (v < -0.9 || h < MIN_LIST - 30) return settle(true);
    if (expandedRef.current && v > 0.6 && h < MIN_LIST) return settle(false);
    const fixed = Math.min(maxH, Math.max(MIN_LIST, h));
    expandedRef.current = false;
    setExpanded(false);
    if (reduce) paneH.set(fixed);
    else void animate(paneH, fixed, SPRING);
    void repo.updateSettings({ homeSplit: Math.round((fixed / Math.max(1, bodyH)) * 1000) / 1000 });
  };
  /** pointercancel（OSのジェスチャー・着信など）では開閉を確定せず、元の状態へ戻す */
  const onHandleCancel = (e: RPointerEvent<HTMLDivElement>) => {
    const d = handleDrag.current;
    handleDrag.current = null;
    gestureLock.release('split');
    if (d && d.id === e.pointerId) settle(expandedRef.current);
  };

  // ---- コンパクト表示（円の列）での縦スワイプ：上へ＝カレンダーへ、下へ＝一覧を戻す（C01） ----
  // 判定は生のポインター差分（圧縮後の座標ではない）。初動8pxまではタップ・横スクロールのまま
  const cg = useRef<{ id: number; x: number; y: number; t: number; vertical: boolean; samples: { y: number; t: number }[] } | null>(null);
  const goCalendar = () => {
    setCalDate(homeDate);
    void repo.updateSettings({ calendarView: settings.homeDays === 1 ? 'day' : '2day' });
    setTab('calendar');
  };
  const onCompactDown = (e: RPointerEvent<HTMLDivElement>) => {
    if (e.button !== 0 || !expandedRef.current) return;
    cg.current = { id: e.pointerId, x: e.clientX, y: e.clientY, t: performance.now(), vertical: false, samples: [{ y: e.clientY, t: performance.now() }] };
  };
  const onCompactMove = (e: RPointerEvent<HTMLDivElement>) => {
    const g = cg.current;
    if (!g || g.id !== e.pointerId) return;
    const dx = e.clientX - g.x;
    const dy = e.clientY - g.y;
    g.samples.push({ y: e.clientY, t: performance.now() });
    if (g.samples.length > 6) g.samples.shift();
    if (!g.vertical) {
      if (Math.hypot(dx, dy) < 8) return;
      if (Math.abs(dx) > Math.abs(dy)) { cg.current = null; return; } // 横は円の列のスクロール
      if (!gestureLock.acquire('split')) { cg.current = null; return; }
      g.vertical = true;
      try { e.currentTarget.setPointerCapture(e.pointerId); } catch { /* noop */ }
    }
  };
  const onCompactUp = (e: RPointerEvent<HTMLDivElement>) => {
    const g = cg.current;
    cg.current = null;
    if (!g || g.id !== e.pointerId || !g.vertical) return;
    gestureLock.release('split');
    const dy = e.clientY - g.y;
    const nowT = performance.now();
    const first = g.samples.find((p) => nowT - p.t < 100) ?? g.samples[0]!;
    const v = (e.clientY - first.y) / Math.max(16, nowT - first.t);
    if (dy <= -36 || v <= -0.65) return goCalendar();
    if (dy >= 36 || v >= 0.65) return settle(false);
  };
  const onCompactCancel = () => { if (cg.current?.vertical) gestureLock.release('split'); cg.current = null; };

  // ホームは1日・2日だけ（3〜7日表示は廃止：Q22）
  const days = settings.homeDays;
  const events = useVisibleEvents(addDays(homeDate, -1), addDays(homeDate, days + 1), now);
  const dayTasks = useMemo(() => tasksForDay(tasks, homeDate), [tasks, homeDate]);
  const doneCount = dayTasks.filter((t) => t.status === 'done').length;
  const isToday = isSameDay(homeDate, now);
  const visibleTasks = useMemo(() => {
    const end = addDays(homeDate, days);
    return tasks.filter((t) => t.kind === 'do' && t.plannedStart != null && t.plannedStart < end && (t.plannedEnd ?? t.plannedStart) > homeDate - 86_400_000);
  }, [tasks, homeDate, days]);

  usePager(listRef, { x: listX, onPage: (dir) => setHomeDate(addDays(homeDate, dir)), reduceMotion: reduce });

  const narrow = navW < 360;
  const moreItems: (MenuItem | 'separator')[] = [
    { label: '今日へ移動', icon: 'today', disabled: isToday, onSelect: () => setHomeDate(startOfDay(Date.now())) },
    // 1日／2日の切替はヘッダーのボタンだけ（二重にしない：C02）。代わりに日付を選ぶ
    { label: '日付を選択', icon: 'calendar', onSelect: () => setDatePick(true) },
    { label: expanded ? 'タスク一覧を表示' : 'タスクをコンパクト表示', icon: 'expand', onSelect: () => settle(!expanded) },
    { label: 'カレンダーで表示', icon: 'calendar', onSelect: goCalendar },
  ];
  const hd = new Date(homeDate);

  return (
    <div className="screen home" data-testid="home-screen" data-expanded={expanded}>
      <header className="nav home-nav">
        {/* 日付ヘッダー（Q19）：月を小さく、日と曜日を大きく。今日は赤い印、別の日はタップで今日へ */}
        <button type="button" className="date-head" onClick={() => !isToday && setHomeDate(startOfDay(Date.now()))} aria-label={`${formatDayLabel(homeDate)}${isToday ? '（今日）' : '。タップで今日へ'}`} data-testid="home-date">
          <span className="date-month">{hd.getFullYear()}年{hd.getMonth() + 1}月</span>
          <span className="date-main">
            <span className={`date-day ${isToday ? 'today' : ''}`}>{hd.getDate()}日</span>
            <span className="date-wd">{'日月火水木金土'[hd.getDay()]}曜日</span>
            {!isToday && <span className="nav-date-today">今日へ</span>}
          </span>
        </button>
        <div className="nav-actions gap">
          <button type="button" className="gbtn glass glass-i" aria-label={settings.homeDays === 1 ? '2日表示に切り替え' : '1日表示に切り替え'} data-testid="days-toggle" data-days={settings.homeDays} onClick={() => void repo.updateSettings({ homeDays: settings.homeDays === 1 ? 2 : 1 })}>
            <Icon name={settings.homeDays === 1 ? 'days1' : 'days2'} size={20} />
          </button>
          {!narrow && <InlineSearch target="home" />}
          {/* ＋は共通の作成画面を直接開く（Q20 を Q38・Q63 で上書き）。ホームの初期種別はタスク */}
          <button type="button" className="gbtn glass glass-i tint" aria-label="追加" onClick={() => openSheet({ kind: 'edit', mode: 'task' })} data-testid="home-add"><Icon name="plus" size={20} strokeWidth={2.2} /></button>
          <MenuButton label="その他の操作" items={moreItems} className="gbtn glass glass-i">
            <Icon name="more" size={20} strokeWidth={3} />
          </MenuButton>
        </div>
      </header>

      <div className="home-body" ref={bodyRef}>
        <motion.section className="task-pane" data-density={density} style={{ height: paneH }} aria-label="タスク一覧" data-testid="task-pane">
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
                    <button type="button" className="link-btn" onClick={() => openSheet({ kind: 'edit', mode: 'task' })}>タスクを追加</button>
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
          <motion.div className="cards-wrap" style={{ opacity: cardsOpacity, pointerEvents: cardsInteractive ? 'auto' : 'none' }} aria-hidden={!cardsInteractive}
            onPointerDown={onCompactDown} onPointerMove={onCompactMove} onPointerUp={onCompactUp} onPointerCancel={onCompactCancel} data-testid="compact-row">
            <FloatingCards tasks={tasks} subtasksByTask={subtasksByTask} now={now} />
          </motion.div>
        </motion.section>

        {/* コンパクト表示ではつまみ・線・その余白を描かない（C01）。戻すのは円の列の下スワイプかメニュー */}
        {!expanded && (
          <div
            className="split-handle"
            role="separator"
            aria-orientation="horizontal"
            aria-label="タスクとカレンダーの境界。上下キーで高さを変更、Home でコンパクト表示"
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={Math.round((normalH / Math.max(1, bodyH)) * 100)}
            aria-valuetext={`タスク一覧 ${Math.round((normalH / Math.max(1, bodyH)) * 100)}%`}
            tabIndex={0}
            style={{ height: HANDLE_H }}
            data-testid="split-handle"
            onPointerDown={onHandleDown}
            onPointerMove={onHandleMove}
            onPointerUp={onHandleUp}
            onPointerCancel={onHandleCancel}
            onKeyDown={(e) => {
              // 無段階の比率をキーボードでも変えられる（R3）
              const step = Math.round(bodyH * 0.05);
              let h: number | null = null;
              if (e.key === 'ArrowUp') h = Math.max(MIN_LIST, normalH - step);
              if (e.key === 'ArrowDown') h = Math.min(maxH, normalH + step);
              if (e.key === 'Home') { e.preventDefault(); return settle(true); }
              if (h == null) return;
              e.preventDefault();
              void repo.updateSettings({ homeSplit: Math.round((h / Math.max(1, bodyH)) * 1000) / 1000 });
            }}
          >
            <span className="split-grip" />
          </div>
        )}

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
            dayLabels={days > 1 ? 'all' : 'afterFirst'}
            onPage={(dir) => setHomeDate(addDays(homeDate, dir))}
            {...actions}
          />
        </div>
      </div>
      <DatePickerPopup open={datePick} value={homeDate} title="日付を選択" onClose={() => setDatePick(false)} onPick={(d) => { setDatePick(false); setHomeDate(d); }} />
    </div>
  );
}
