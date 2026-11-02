import { useEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent } from 'react';
import { motion, useMotionValue, useReducedMotion } from 'motion/react';
import {
  addDays, formatHm, isSameDay, layoutDay, MINUTE, overlaps, snapToStep, startOfDay, taskBlock, weekdayJa,
  type CalEvent, type Calendar, type Subtask, type Task, type TaskBlock,
} from '@my-time/domain';
import { blockTouchScrollWhile, gestureLock } from '../../gestures/gestureLock';
import { usePager } from '../../gestures/usePager';
import { EventBadge, TaskBadge } from '../../components/Identity';
import { clampScroll, edgeScrollSpeed } from './edgeScroll';

export type DayLabelMode = 'none' | 'afterFirst' | 'all';

interface Props {
  startDay: number;
  days: number;
  now: number;
  events: CalEvent[];
  tasks: Task[];
  subtasksByTask: Map<string, Subtask[]>;
  calendarById: Map<string, Calendar>;
  dayLabels: DayLabelMode;
  onPage: (dir: 1 | -1) => void;
  onOpenEvent: (id: string) => void;
  onOpenTask: (id: string) => void;
  /** 移動の確定要求。重複確認などが終わるまで仮位置を表示し続ける。 */
  onMove: (kind: 'event' | 'task', id: string, newStart: number) => Promise<void>;
  /** 予定の静止長押し（タスクでは呼ばない：タスクの編集・削除はタップ後の詳細シートから） */
  onEventMenu: (id: string, anchor?: HTMLElement | null) => void;
  onTapDay?: (day: number) => void;
  /** 空白の長押し→指で範囲を選んで離す：新規予定の作成（DB にはまだ書かない：Q27） */
  onCreateRange?: (start: number, end: number) => void;
  /** 予定の上下端をつかんで長さを変える（15分刻み：Q29） */
  onResize?: (id: string, start: number, end: number) => Promise<void>;
  testId?: string;
}

type Item =
  | { id: string; kind: 'event'; start: number; end: number; event: CalEvent }
  | { id: string; kind: 'task'; start: number; end: number; task: Task; block: TaskBlock };

interface DragState {
  item: Item;
  pointerId: number;
  startX: number;
  startY: number;
  /** 長押しを開始した列（日付またぎ予定の2日目を掴んだ場合にも正しく動かすため） */
  grabCol: number;
  active: boolean;
  moved: boolean;
  deltaMin: number;
  deltaDays: number;
  /** 長押し開始時のスクロール位置（端の自動スクロール中も指の下の時刻を保つ） */
  startScroll: number;
  lastX: number;
  lastY: number;
  /** move=移動 / start・end=上端・下端の伸縮 */
  mode: 'move' | 'start' | 'end';
}

/** 空白の長押しで作る新規予定の仮範囲 */
interface CreateState { pointerId: number; dayStart: number; colTop: number; x0: number; y0: number; anchorMin: number; curMin: number; active: boolean }

/** ドラッグ中または確認待ちの仮位置 */
interface Ghost {
  item: Item;
  start: number;
  /** 伸縮のときの終了（省略時は元の長さ） */
  end?: number;
  pending: boolean;
}

const MIN_H = 22;
const MAX_H = 160;
const DEFAULT_H = 52;
const LONG_PRESS_MS = 420;
const SNAP_MIN = 15;

/** 分 → CSS の長さ（時間軸の倍率は CSS 変数 --hour だけで変える） */
const mins = (m: number) => `calc(var(--hour) * ${(m / 60).toFixed(5)})`;

const itemDuration = (it: Item) => (it.kind === 'task' ? it.block.plannedEnd : it.end) - it.start;
const realId = (it: Item) => (it.kind === 'event' ? it.event.id : it.task.id);

/** Appleカレンダー風の時間軸。縦スクロール／ピンチ倍率はこの領域内だけで処理する。 */
export function Timeline(props: Props) {
  const { startDay, days, now, events, tasks, subtasksByTask, calendarById, dayLabels, onPage, onOpenEvent, onOpenTask, onMove, onEventMenu, onTapDay, onCreateRange, onResize, testId } = props;
  const createRef = useRef<CreateState | null>(null);
  const [creating, setCreating] = useState<CreateState | null>(null);
  /** 確定済みの倍率（文字の出し分けなどに使う）。ピンチ中は CSS 変数だけを毎フレーム更新する。 */
  const [hourH, setHourH] = useState(DEFAULT_H);
  const liveHour = useRef(DEFAULT_H);
  const rootRef = useRef<HTMLDivElement>(null);
  const scrollRef = useRef<HTMLDivElement>(null);
  const colsRef = useRef<HTMLDivElement>(null);
  const pagerRef = useRef<HTMLDivElement>(null);
  const reduce = useReducedMotion() ?? false;
  const x = useMotionValue(0);
  const [drag, setDrag] = useState<DragState | null>(null);
  const dragRef = useRef<DragState | null>(null);
  const [pending, setPending] = useState<Ghost | null>(null);
  const timerRef = useRef<number | undefined>(undefined);
  const suppressClick = useRef(false);

  usePager(pagerRef, { x, onPage, enabled: !pending, reduceMotion: reduce });

  const applyHour = (h: number) => {
    liveHour.current = h;
    rootRef.current?.style.setProperty('--hour', `${h}px`);
  };

  // 初回は現在時刻（なければ8時）付近へ。ユーザーが触るまでは、画面サイズが落ち着く（ホームの上下分割が確定する）たびに合わせ直す
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    let anchored = true;
    let lastSet = -1;
    const anchor = () => {
      if (!anchored) return;
      const d = new Date(now);
      const minutes = isSameDay(now, startDay) || days > 1 ? d.getHours() * 60 + d.getMinutes() : 8 * 60;
      el.scrollTop = Math.max(0, (minutes * liveHour.current) / 60 - el.clientHeight * 0.35);
      lastSet = el.scrollTop;
    };
    const release = () => {
      anchored = false;
    };
    // 自分で合わせた位置以外へスクロールされたら（ユーザー操作・プログラムによる移動とも）以後は合わせ直さない
    const onScroll = () => {
      if (Math.abs(el.scrollTop - lastSet) > 2) anchored = false;
    };
    el.addEventListener('scroll', onScroll, { passive: true });
    anchor();
    const ro = new ResizeObserver(anchor);
    ro.observe(el);
    el.addEventListener('pointerdown', release, { passive: true });
    el.addEventListener('touchstart', release, { passive: true });
    el.addEventListener('wheel', release, { passive: true });
    return () => {
      ro.disconnect();
      el.removeEventListener('scroll', onScroll);
      el.removeEventListener('pointerdown', release);
      el.removeEventListener('touchstart', release);
      el.removeEventListener('wheel', release);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // ピンチ／トラックパッドで時間軸だけを拡大縮小（ページ全体のズームを起こさない）。
  // 再描画せず CSS 変数とスクロール位置だけを毎フレーム更新し、指の間の時刻を固定したまま滑らかに伸縮する。
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    let pinch: { d0: number; h0: number; focalMin: number; focalY: number } | null = null;
    let raf = 0;
    let commitTimer = 0;
    let next: { h: number; focalMin: number; focalY: number } | null = null;
    const dist = (t: TouchList) => Math.hypot(t[0]!.clientX - t[1]!.clientX, t[0]!.clientY - t[1]!.clientY);
    const flush = () => {
      raf = 0;
      if (!next) return;
      const h = Math.min(MAX_H, Math.max(MIN_H, next.h));
      applyHour(h);
      el.scrollTop = (next.focalMin * h) / 60 - next.focalY;
      next = null;
    };
    const schedule = (h: number, focalMin: number, focalY: number) => {
      next = { h, focalMin, focalY };
      if (!raf) raf = requestAnimationFrame(flush);
    };
    const commit = () => setHourH(Math.round(liveHour.current * 10) / 10);
    const ts = (e: TouchEvent) => {
      if (e.touches.length === 2) {
        const rect = el.getBoundingClientRect();
        const focalY = (e.touches[0]!.clientY + e.touches[1]!.clientY) / 2 - rect.top;
        const h = liveHour.current;
        pinch = { d0: dist(e.touches), h0: h, focalY, focalMin: ((el.scrollTop + focalY) / h) * 60 };
        rootRef.current?.classList.add('pinching');
      }
    };
    const tm = (e: TouchEvent) => {
      if (pinch && e.touches.length === 2) {
        if (e.cancelable) e.preventDefault();
        schedule(pinch.h0 * (dist(e.touches) / pinch.d0), pinch.focalMin, pinch.focalY);
      }
    };
    const te = (e: TouchEvent) => {
      if (pinch && e.touches.length < 2) {
        pinch = null;
        rootRef.current?.classList.remove('pinching');
        commit();
      }
    };
    const wheel = (e: WheelEvent) => {
      if (!e.ctrlKey) return;
      e.preventDefault();
      const rect = el.getBoundingClientRect();
      const focalY = e.clientY - rect.top;
      const h = next?.h ?? liveHour.current;
      schedule(h * Math.exp(-e.deltaY / 120), ((el.scrollTop + focalY) / liveHour.current) * 60, focalY);
      window.clearTimeout(commitTimer);
      commitTimer = window.setTimeout(commit, 160);
    };
    const gesture = (e: Event) => e.preventDefault(); // Safari のページピンチ
    el.addEventListener('touchstart', ts, { passive: true });
    el.addEventListener('touchmove', tm, { passive: false });
    el.addEventListener('touchend', te);
    el.addEventListener('touchcancel', te);
    el.addEventListener('wheel', wheel, { passive: false });
    el.addEventListener('gesturestart', gesture);
    el.addEventListener('gesturechange', gesture);
    const unblock = blockTouchScrollWhile(el, () => dragRef.current?.active === true || createRef.current?.active === true);
    return () => {
      cancelAnimationFrame(raf);
      window.clearTimeout(commitTimer);
      el.removeEventListener('touchstart', ts);
      el.removeEventListener('touchmove', tm);
      el.removeEventListener('touchend', te);
      el.removeEventListener('touchcancel', te);
      el.removeEventListener('wheel', wheel);
      el.removeEventListener('gesturestart', gesture);
      el.removeEventListener('gesturechange', gesture);
      unblock();
    };
  }, []);

  const dayStarts = useMemo(() => Array.from({ length: days }, (_, i) => addDays(startDay, i)), [startDay, days]);

  const items: Item[] = useMemo(() => {
    const out: Item[] = events.filter((e) => !e.extra?.allDay).map((e) => ({ id: `event:${e.id}`, kind: 'event', start: e.start, end: e.end, event: e }));
    for (const t of tasks) {
      const b = taskBlock(t, subtasksByTask.get(t.id) ?? [], now);
      if (b) out.push({ id: b.id, kind: 'task', start: b.start, end: b.end, task: t, block: b });
    }
    return out;
  }, [events, tasks, subtasksByTask, now]);

  // ---- 予定・タスクの長押しドラッグ（15分スナップ。確定は onMove 側の確認後） ----
  const setDragBoth = (d: DragState | null) => {
    dragRef.current = d;
    setDrag(d);
  };
  const colWidth = () => (colsRef.current?.clientWidth ?? 300) / days;
  const ghostStart = (d: DragState) => snapToStep(addDays(d.item.start, d.deltaDays) + d.deltaMin * MINUTE, SNAP_MIN);

  const onItemPointerDown = (e: RPointerEvent, item: Item, col: number) => {
    if (e.button !== 0 || dragRef.current || pending) return;
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    // 予定の上端・下端（約10px）をつかんだときは伸縮（Q29）。それ以外は移動
    const mode: DragState['mode'] = item.kind === 'event' && rect.height >= 30 ? (e.clientY - rect.top < 10 ? 'start' : rect.bottom - e.clientY < 10 ? 'end' : 'move') : 'move';
    const d: DragState = { item, pointerId: e.pointerId, startX: e.clientX, startY: e.clientY, grabCol: col, active: false, moved: false, deltaMin: 0, deltaDays: 0, startScroll: scrollRef.current?.scrollTop ?? 0, lastX: e.clientX, lastY: e.clientY, mode };
    dragRef.current = d;
    const target = e.currentTarget as HTMLElement;
    window.clearTimeout(timerRef.current);
    timerRef.current = window.setTimeout(() => {
      const cur = dragRef.current;
      if (!cur || cur.item.id !== item.id) return;
      if (!gestureLock.acquire('timeline-drag')) return;
      try {
        target.setPointerCapture(cur.pointerId);
      } catch {
        /* noop */
      }
      navigator.vibrate?.(8);
      setDragBoth({ ...cur, active: true, startScroll: scrollRef.current?.scrollTop ?? cur.startScroll });
      startEdgeLoop();
    }, LONG_PRESS_MS);
  };

  const onItemPointerMove = (e: RPointerEvent) => {
    const d = dragRef.current;
    if (!d || e.pointerId !== d.pointerId) return;
    const dx = e.clientX - d.startX;
    const dy = e.clientY - d.startY;
    if (!d.active) {
      if (Math.hypot(dx, dy) > 8) {
        window.clearTimeout(timerRef.current);
        dragRef.current = null;
      }
      return;
    }
    updateDrag(d, e.clientX, e.clientY);
  };

  /** 指の位置（とスクロール量）から仮位置を計算する。端の自動スクロール中は指が止まっていても呼ぶ */
  const updateDrag = (d: DragState, x: number, y: number) => {
    const scrolled = (scrollRef.current?.scrollTop ?? d.startScroll) - d.startScroll;
    const dx = x - d.startX;
    const dy = y - d.startY + scrolled;
    const deltaMin = Math.round(dy / (liveHour.current / 60) / SNAP_MIN) * SNAP_MIN;
    const deltaDays = days > 1 && d.mode === 'move' ? Math.min(days - 1 - d.grabCol, Math.max(-d.grabCol, Math.round(dx / colWidth()))) : 0;
    const moved = d.moved || Math.hypot(x - d.startX, y - d.startY) > 6 || Math.abs(scrolled) > 6;
    if (deltaMin !== d.deltaMin || deltaDays !== d.deltaDays || moved !== d.moved) setDragBoth({ ...d, deltaMin, deltaDays, moved, lastX: x, lastY: y });
    else dragRef.current = { ...d, lastX: x, lastY: y };
  };

  // ---- ドラッグ中、指が時間軸の上端・下端に近づいたら自動でスクロール（タブバーに隠れる部分は端に含めない） ----
  const edgeRaf = useRef(0);
  const startEdgeLoop = () => {
    cancelAnimationFrame(edgeRaf.current);
    const step = () => {
      const d = dragRef.current;
      const el = scrollRef.current;
      if (!d?.active || !el) return;
      // 静止した長押し（端の近くの予定を掴んだだけ）では流さない。指を動かして端へ運んだときだけ
      if (Math.hypot(d.lastX - d.startX, d.lastY - d.startY) < 12) {
        edgeRaf.current = requestAnimationFrame(step);
        return;
      }
      const rect = el.getBoundingClientRect();
      const bar = document.querySelector('.tabbar-glass')?.getBoundingClientRect();
      const bottom = bar && bar.top < rect.bottom && bar.top > rect.top ? bar.top : rect.bottom;
      const v = clampScroll(edgeScrollSpeed(d.lastY, rect.top, bottom), el.scrollTop, el.scrollHeight - el.clientHeight);
      if (v !== 0) {
        el.scrollTop += v;
        updateDrag(d, d.lastX, d.lastY);
      }
      edgeRaf.current = requestAnimationFrame(step);
    };
    edgeRaf.current = requestAnimationFrame(step);
  };
  useEffect(() => () => cancelAnimationFrame(edgeRaf.current), []);

  const finishDrag = (commit: boolean) => {
    window.clearTimeout(timerRef.current);
    cancelAnimationFrame(edgeRaf.current);
    const d = dragRef.current;
    setDragBoth(null);
    gestureLock.release('timeline-drag');
    if (!d || !d.active) return;
    suppressClick.current = true;
    window.setTimeout(() => (suppressClick.current = false), 50);
    if (!commit) return; // pointercancel では何も変えない
    if (d.mode !== 'move') {
      if (d.moved && d.deltaMin !== 0 && onResize) {
        const rr = resizeRange(d);
        setPending({ item: d.item, ...rr, pending: true });
        void onResize(realId(d.item), rr.start, rr.end).finally(() => setPending(null));
      } else if (!d.moved && d.item.kind === 'event') onEventMenu(d.item.event.id, rootRef.current?.querySelector(`[data-testid="tl-event:${d.item.event.id}"]`) as HTMLElement | null);
      return;
    }
    if (d.moved && (d.deltaMin !== 0 || d.deltaDays !== 0)) {
      const start = ghostStart(d);
      setPending({ item: d.item, start, pending: true });
      void onMove(d.item.kind, realId(d.item), start).finally(() => setPending(null));
    } else if (!d.moved && d.item.kind === 'event') {
      onEventMenu(d.item.event.id, rootRef.current?.querySelector(`[data-testid="tl-event:${d.item.event.id}"]`) as HTMLElement | null);
    }
    // タスクの静止長押しは何もしない（持ち上げを戻すだけ）
  };

  const onItemClick = (item: Item) => {
    if (suppressClick.current) return;
    if (item.kind === 'event') onOpenEvent(item.event.id);
    else onOpenTask(item.task.id);
  };

  const resizeRange = (d: DragState) => {
    if (d.mode === 'end') return { start: d.item.start, end: Math.max(d.item.start + SNAP_MIN * MINUTE, snapToStep(d.item.end + d.deltaMin * MINUTE, SNAP_MIN)) };
    return { start: Math.min(d.item.end - SNAP_MIN * MINUTE, snapToStep(d.item.start + d.deltaMin * MINUTE, SNAP_MIN)), end: d.item.end };
  };
  const ghost: Ghost | null = drag?.active && drag.moved ? (drag.mode === 'move' ? { item: drag.item, start: ghostStart(drag), pending: false } : { item: drag.item, ...resizeRange(drag), pending: false }) : pending;
  const ghostConflict = ghost
    ? items.some((o) => o.id !== ghost.item.id && !(o.kind === 'task' && o.task.status === 'done') && overlaps({ start: ghost.start, end: ghost.start + itemDuration(ghost.item) }, o))
    : false;
  const hiddenId = drag?.active ? drag.item.id : pending?.item.id;

  // ---- 空白の長押しで新規予定（Q27）：長押しで仮予定が現れ、指で範囲を選び、離すと編集画面へ ----
  const minAt = (cs: CreateState, clientY: number) => {
    const col = rootRef.current?.querySelector(`[data-date="${cs.dayStart}"]`) as HTMLElement | null;
    const y = clientY - (col?.getBoundingClientRect().top ?? 0);
    return Math.max(0, Math.min(24 * 60, (y / liveHour.current) * 60));
  };
  const onColPointerDown = (e: RPointerEvent<HTMLDivElement>, dayStart: number) => {
    if (e.button !== 0 || e.target !== e.currentTarget || !onCreateRange || dragRef.current || pending) return;
    const cs: CreateState = { pointerId: e.pointerId, dayStart, colTop: 0, x0: e.clientX, y0: e.clientY, anchorMin: 0, curMin: 0, active: false };
    cs.anchorMin = Math.floor(minAt(cs, e.clientY) / SNAP_MIN) * SNAP_MIN;
    cs.curMin = cs.anchorMin + 60;
    createRef.current = cs;
    const target = e.currentTarget;
    window.clearTimeout(timerRef.current);
    timerRef.current = window.setTimeout(() => {
      if (createRef.current !== cs) return;
      if (!gestureLock.acquire('timeline-drag')) return;
      try { target.setPointerCapture(cs.pointerId); } catch { /* noop */ }
      navigator.vibrate?.(8);
      cs.active = true;
      setCreating({ ...cs });
    }, LONG_PRESS_MS);
  };
  const onColPointerMove = (e: RPointerEvent<HTMLDivElement>) => {
    const cs = createRef.current;
    if (!cs || e.pointerId !== cs.pointerId) return;
    if (!cs.active) {
      if (Math.hypot(e.clientX - cs.x0, e.clientY - cs.y0) > 8) { window.clearTimeout(timerRef.current); createRef.current = null; }
      return;
    }
    const m = Math.round(minAt(cs, e.clientY) / SNAP_MIN) * SNAP_MIN;
    const cur = m <= cs.anchorMin ? Math.min(m, cs.anchorMin - SNAP_MIN) : Math.max(m, cs.anchorMin + SNAP_MIN);
    if (cur !== cs.curMin && Math.abs(e.clientY - cs.y0) > 6) { cs.curMin = cur; setCreating({ ...cs }); }
  };
  const onColPointerUp = (e: RPointerEvent<HTMLDivElement>, commit: boolean) => {
    const cs = createRef.current;
    if (!cs || e.pointerId !== cs.pointerId) return;
    window.clearTimeout(timerRef.current);
    createRef.current = null;
    setCreating(null);
    if (!cs.active) return;
    gestureLock.release('timeline-drag');
    suppressClick.current = true;
    window.setTimeout(() => (suppressClick.current = false), 50);
    if (!commit) return; // キャンセル：何も作らない
    const a = Math.min(cs.anchorMin, cs.curMin);
    const b = Math.max(cs.anchorMin, cs.curMin);
    onCreateRange?.(cs.dayStart + a * MINUTE, cs.dayStart + b * MINUTE);
  };

  // 終日の予定は時間軸の上の専用領域へ（Q30）
  const allDayByCol = dayStarts.map((d) => events.filter((e) => e.extra?.allDay && e.start < addDays(d, 1) && e.end > d));
  const todayIdxAll = dayStarts.findIndex((d) => isSameDay(d, now));
  const nowMinAll = (now - startOfDay(now)) / MINUTE;
  const renderColumn = (dayStart: number, colIndex: number) => {
    const todayIdx = todayIdxAll;
    const dayEnd = addDays(dayStart, 1);
    const dayItems = items.filter((it) => it.start < dayEnd && it.end > dayStart);
    const delayedTasks = dayItems.filter((it): it is Extract<Item, { kind: 'task' }> => it.kind === 'task' && it.block.delayed);
    const normal = dayItems.filter((it) => !(it.kind === 'task' && it.block.delayed));
    const placed = layoutDay(normal, dayStart);
    const placedDelayed = layoutDay(delayedTasks, dayStart);
    const extensionWindows = delayedTasks.map((t) => ({ start: t.block.plannedEnd, end: Math.max(t.block.end, t.block.eta ?? 0) }));
    const isToday = isSameDay(dayStart, now);
    const nowMin = (now - startOfDay(now)) / MINUTE;
    const showTime = (heightMin: number) => (heightMin * hourH) / 60 > 34;

    const renderBlock = (p: (typeof placed)[number], overlay: boolean) => {
      const it = p.item;
      const greyed = !overlay && it.kind === 'event' && extensionWindows.some((w) => overlaps(w, it));
      const cal = it.kind === 'event' ? calendarById.get(it.event.calendarId) : it.task.calendarId ? calendarById.get(it.task.calendarId) : undefined;
      const color = it.kind === 'task' ? 'var(--blue)' : cal?.color ?? 'var(--blue)';
      const leftPct = overlay ? 0 : (p.column / p.columns) * 100;
      const widthPct = overlay ? 100 : 100 / p.columns;
      const title = it.kind === 'event' ? it.event.title : it.task.title;
      const timeText = `${formatHm(it.start)}〜${formatHm(it.kind === 'task' ? it.block.plannedEnd : it.end)}`;
      const planEndMin = it.kind === 'task' && it.block.delayed ? (it.block.plannedEnd - Math.max(it.start, dayStart)) / MINUTE : null;
      const etaAt = it.kind === 'task' ? it.block.eta : null;
      const etaMin = etaAt != null && etaAt > it.end ? (Math.min(etaAt, dayEnd) - it.end) / MINUTE : 0;
      return (
        <button
          key={it.id}
          type="button"
          className={`tl-block ${it.kind} ${greyed ? 'greyed' : ''} ${overlay ? 'overlay' : ''} ${hiddenId === it.id ? 'lifted-ghost' : ''} ${it.kind === 'task' ? `st-${it.task.status}` : ''} ${p.clippedStart ? 'clip-start' : ''} ${p.clippedEnd ? 'clip-end' : ''}`}
          style={{
            top: mins(p.top),
            height: `max(18px, calc(${mins(p.height)} - 2px))`,
            left: `calc(${leftPct}% + 1px)`,
            width: `calc(${widthPct}% - 3px)`,
            ['--c' as string]: color,
          }}
          aria-label={`${it.kind === 'task' ? 'タスク' : '予定'} ${title}、${timeText}${it.kind === 'task' && it.block.delayed ? '、遅延中' : ''}`}
          data-testid={`tl-${it.id}`}
          data-day={colIndex}
          onPointerDown={(e) => onItemPointerDown(e, it, colIndex)}
          onPointerMove={onItemPointerMove}
          onPointerUp={() => finishDrag(true)}
          onPointerCancel={() => finishDrag(false)}
          onClick={() => onItemClick(it)}
          onContextMenu={(e) => e.preventDefault()}
        >
          {planEndMin != null && planEndMin < p.height && <span className="tl-overrun" style={{ top: mins(Math.max(0, planEndMin)) }} aria-hidden />}
          <span className="tl-title">
            {/* 予定は角丸四角、タスクは円（実行は赤・確認は青）で区別（C28） */}
            {it.kind === 'task' ? <TaskBadge icon={it.task.icon} kind={it.task.kind === 'check' ? 'check' : 'do'} size={16} done={it.task.status === 'done' || !!it.task.checked} className="tl-ticon" /> : <EventBadge icon={cal?.icon} color={it.event.extra?.color ?? cal?.color ?? 'var(--blue)'} size={16} className="tl-ticon ev" />}
            {title}
          </span>
          {showTime(p.height) && <span className="tl-time">{timeText}</span>}
          {etaMin > 0 && etaAt != null && (
            <span className="tl-eta" style={{ height: mins(etaMin) }} aria-label={`予測終了 ${formatHm(etaAt)}`}>
              <span className="tl-eta-label">予測 {formatHm(etaAt)}</span>
            </span>
          )}
        </button>
      );
    };

    // 仮位置：日付をまたぐ場合も、重なる各列に切り分けて表示する
    let ghostEl = null;
    if (ghost) {
      const gs = ghost.start;
      const ge = ghost.end ?? gs + itemDuration(ghost.item);
      if (gs < dayEnd && ge > dayStart) {
        const s = Math.max(gs, dayStart);
        const e = Math.min(ge, dayEnd);
        const c = ghost.item.kind === 'task' ? 'var(--blue)' : calendarById.get(ghost.item.event.calendarId)?.color ?? 'var(--blue)';
        ghostEl = (
          <div
            className={`tl-block lifted ${ghostConflict ? 'conflict' : ''} ${ghost.pending ? 'pending' : ''} ${gs < dayStart ? 'clip-start' : ''} ${ge > dayEnd ? 'clip-end' : ''}`}
            style={{ top: mins((s - dayStart) / MINUTE), height: `max(18px, calc(${mins((e - s) / MINUTE)} - 2px))`, left: 1, width: 'calc(100% - 3px)', ['--c' as string]: c }}
            data-testid="tl-ghost"
            aria-hidden
          >
            <span className="tl-title">{ghost.item.kind === 'event' ? ghost.item.event.title : ghost.item.task.title}</span>
            <span className="tl-time">{formatHm(gs)}〜{formatHm(ge)}</span>
          </div>
        );
      }
    }

    return (
      <div
        className={`tl-col ${isToday ? 'today' : ''}`}
        key={dayStart}
        data-testid={`tl-col-${colIndex}`}
        data-date={dayStart}
        onPointerDown={(e) => onColPointerDown(e, dayStart)}
        onPointerMove={onColPointerMove}
        onPointerUp={(e) => onColPointerUp(e, true)}
        onPointerCancel={(e) => onColPointerUp(e, false)}
        onContextMenu={(e) => e.preventDefault()}
      >
        {creating && creating.dayStart === dayStart && (
          <div className="tl-block lifted creating" data-testid="tl-create-ghost" aria-hidden style={{ top: mins(Math.min(creating.anchorMin, creating.curMin)), height: `calc(${mins(Math.abs(creating.curMin - creating.anchorMin))} - 2px)`, left: 1, width: 'calc(100% - 3px)', ['--c' as string]: 'var(--blue)' }}>
            <span className="tl-title">新規予定</span>
            <span className="tl-time">{formatHm(dayStart + Math.min(creating.anchorMin, creating.curMin) * MINUTE)}〜{formatHm(dayStart + Math.max(creating.anchorMin, creating.curMin) * MINUTE)}</span>
          </div>
        )}
        {!isToday && todayIdx >= 0 && <div className="tl-now-guide" style={{ top: mins(nowMinAll) }} aria-hidden />}
        {placed.map((p) => renderBlock(p, false))}
        {placedDelayed.map((p) => renderBlock(p, true))}
        {ghostEl}
        {isToday && (
          <div className="tl-now" style={{ top: mins(nowMin) }} data-testid="now-line" aria-hidden>
            <span className="tl-now-dot" />
          </div>
        )}
      </div>
    );
  };

  const todayIdx = dayStarts.findIndex((d) => isSameDay(d, now));
  const nowMin = (now - startOfDay(now)) / MINUTE;
  const hours = Array.from({ length: 25 }, (_, h) => h);
  const gridClass = hourH >= 110 ? 'q' : hourH >= 70 ? 'h' : '';

  return (
    <div className="timeline" ref={rootRef} data-testid={testId} data-hour={hourH} style={{ ['--hour' as string]: `${liveHour.current}px` }}>
      {dayLabels !== 'none' && !(dayLabels === 'afterFirst' && days === 1) && (
        <div className="tl-head">
          <div className="tl-gutter-head" />
          <motion.div className="tl-head-cols" style={{ x }}>
            {dayStarts.map((d, i) => (
              <button
                type="button"
                key={d}
                className={`tl-day-label ${isSameDay(d, now) ? 'today' : ''} ${dayLabels === 'afterFirst' && i === 0 ? 'hidden' : ''}`}
                onClick={() => onTapDay?.(d)}
                tabIndex={dayLabels === 'afterFirst' && i === 0 ? -1 : 0}
                aria-hidden={dayLabels === 'afterFirst' && i === 0}
              >
                <span className="wd">{weekdayJa(d)}</span>
                <span className="dn">{new Date(d).getDate()}</span>
              </button>
            ))}
          </motion.div>
        </div>
      )}
      {allDayByCol.some((l) => l.length > 0) && (
        <div className="tl-allday" data-testid="tl-allday">
          <div className="tl-gutter-head tl-allday-label">終日</div>
          <motion.div className="tl-allday-cols" style={{ x, gridTemplateColumns: `repeat(${days}, minmax(0, 1fr))` }}>
            {allDayByCol.map((list, i) => (
              <div key={i} className="tl-allday-col">
                {list.slice(0, 3).map((ev) => (
                  <button key={ev.id} type="button" className="tl-allday-item" style={{ ['--c' as string]: ev.extra?.color ?? calendarById.get(ev.calendarId)?.color ?? 'var(--blue)' }} onClick={() => onOpenEvent(ev.id)} data-testid={`tl-allday:${ev.id}`}>
                    {ev.title}
                  </button>
                ))}
                {list.length > 3 && <span className="tl-allday-more">他{list.length - 3}件</span>}
              </div>
            ))}
          </motion.div>
        </div>
      )}
      <div className="tl-scroll" ref={scrollRef} data-testid={testId ? `${testId}-scroll` : undefined}>
        <div className="tl-canvas" style={{ height: mins(24 * 60) }}>
          <div className="tl-gutter" aria-hidden>
            {hours.map((h) => {
              const nearNow = todayIdx >= 0 && (Math.abs(nowMin - h * 60) * hourH) / 60 < 14;
              return (
                <span key={h} className={`tl-hour ${nearNow ? 'faded' : ''}`} style={{ top: mins(h * 60) }}>
                  {h === 24 ? '' : `${h}:00`}
                </span>
              );
            })}
            {todayIdx >= 0 && (
              <span className="tl-now-label" style={{ top: mins(nowMin) }} data-testid="now-label">
                {formatHm(now)}
              </span>
            )}
          </div>
          <div className="tl-pager" ref={pagerRef}>
            <motion.div className={`tl-cols grid-${gridClass}`} ref={colsRef} style={{ x, gridTemplateColumns: `repeat(${days}, minmax(0, 1fr))` }}>
              {dayStarts.map((d, i) => renderColumn(d, i))}
            </motion.div>
          </div>
        </div>
      </div>
    </div>
  );
}
