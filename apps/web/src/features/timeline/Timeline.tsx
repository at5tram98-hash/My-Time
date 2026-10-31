import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type PointerEvent as RPointerEvent } from 'react';
import { motion, useMotionValue, useReducedMotion } from 'motion/react';
import {
  addDays, formatHm, isSameDay, layoutDay, MINUTE, overlaps, snapToStep, startOfDay, taskBlock, weekdayJa,
  type CalEvent, type Calendar, type Subtask, type Task, type TaskBlock,
} from '@my-time/domain';
import { blockTouchScrollWhile, gestureLock } from '../../gestures/gestureLock';
import { usePager } from '../../gestures/usePager';

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
  onMove: (kind: 'event' | 'task', id: string, newStart: number) => void;
  onItemMenu: (kind: 'event' | 'task', id: string) => void;
  onTapDay?: (day: number) => void;
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
  active: boolean;
  moved: boolean;
  deltaMin: number;
  deltaDays: number;
}

const MIN_H = 22;
const MAX_H = 160;
const LONG_PRESS_MS = 420;
const SNAP_MIN = 15;

/** Appleカレンダー風の時間軸。縦スクロール／ピンチ倍率はこの領域内だけで処理する。 */
export function Timeline(props: Props) {
  const { startDay, days, now, events, tasks, subtasksByTask, calendarById, dayLabels, onPage, onOpenEvent, onOpenTask, onMove, onItemMenu, onTapDay, testId } = props;
  const [hourH, setHourH] = useState(52);
  const scrollRef = useRef<HTMLDivElement>(null);
  const colsRef = useRef<HTMLDivElement>(null);
  const pagerRef = useRef<HTMLDivElement>(null);
  const reduce = useReducedMotion() ?? false;
  const x = useMotionValue(0);
  const pendingScroll = useRef<number | null>(null);
  const [drag, setDrag] = useState<DragState | null>(null);
  const dragRef = useRef<DragState | null>(null);
  const timerRef = useRef<number | undefined>(undefined);
  const suppressClick = useRef(false);
  const pxPerMin = hourH / 60;
  const hourRef = useRef(hourH);
  hourRef.current = hourH;

  usePager(pagerRef, { x, onPage, reduceMotion: reduce });

  // 初回は現在時刻（なければ8時）付近へ
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const d = new Date(now);
    const minutes = isSameDay(now, startDay) || days > 1 ? d.getHours() * 60 + d.getMinutes() : 8 * 60;
    el.scrollTop = Math.max(0, minutes * pxPerMin - el.clientHeight * 0.35);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useLayoutEffect(() => {
    if (pendingScroll.current != null && scrollRef.current) {
      scrollRef.current.scrollTop = pendingScroll.current;
      pendingScroll.current = null;
    }
  }, [hourH]);

  // ピンチ／トラックパッドで時間軸だけを拡大縮小（ページ全体のズームを起こさない）
  useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    let pinch: { d0: number; h0: number; focalMin: number; focalY: number } | null = null;
    const dist = (t: TouchList) => Math.hypot(t[0]!.clientX - t[1]!.clientX, t[0]!.clientY - t[1]!.clientY);
    const zoomTo = (h: number, focalMin: number, focalY: number) => {
      const nh = Math.min(MAX_H, Math.max(MIN_H, h));
      pendingScroll.current = (focalMin * nh) / 60 - focalY;
      setHourH(nh);
    };
    const ts = (e: TouchEvent) => {
      if (e.touches.length === 2) {
        const rect = el.getBoundingClientRect();
        const focalY = (e.touches[0]!.clientY + e.touches[1]!.clientY) / 2 - rect.top;
        const h = hourRef.current;
        pinch = { d0: dist(e.touches), h0: h, focalY, focalMin: ((el.scrollTop + focalY) / h) * 60 };
      }
    };
    const tm = (e: TouchEvent) => {
      if (pinch && e.touches.length === 2) {
        if (e.cancelable) e.preventDefault();
        zoomTo(pinch.h0 * (dist(e.touches) / pinch.d0), pinch.focalMin, pinch.focalY);
      }
    };
    const te = (e: TouchEvent) => {
      if (e.touches.length < 2) pinch = null;
    };
    const wheel = (e: WheelEvent) => {
      if (!e.ctrlKey) return;
      e.preventDefault();
      const rect = el.getBoundingClientRect();
      const focalY = e.clientY - rect.top;
      const h = hourRef.current;
      zoomTo(h * Math.exp(-e.deltaY / 120), ((el.scrollTop + focalY) / h) * 60, focalY);
    };
    const gesture = (e: Event) => e.preventDefault(); // Safari のページピンチ
    el.addEventListener('touchstart', ts, { passive: true });
    el.addEventListener('touchmove', tm, { passive: false });
    el.addEventListener('touchend', te);
    el.addEventListener('wheel', wheel, { passive: false });
    el.addEventListener('gesturestart', gesture);
    el.addEventListener('gesturechange', gesture);
    const unblock = blockTouchScrollWhile(el, () => dragRef.current?.active === true);
    return () => {
      el.removeEventListener('touchstart', ts);
      el.removeEventListener('touchmove', tm);
      el.removeEventListener('touchend', te);
      el.removeEventListener('wheel', wheel);
      el.removeEventListener('gesturestart', gesture);
      el.removeEventListener('gesturechange', gesture);
      unblock();
    };
  }, []);

  const dayStarts = useMemo(() => Array.from({ length: days }, (_, i) => addDays(startDay, i)), [startDay, days]);

  const items: Item[] = useMemo(() => {
    const out: Item[] = events.map((e) => ({ id: `event:${e.id}`, kind: 'event', start: e.start, end: e.end, event: e }));
    for (const t of tasks) {
      const b = taskBlock(t, subtasksByTask.get(t.id) ?? [], now);
      if (b) out.push({ id: b.id, kind: 'task', start: b.start, end: b.end, task: t, block: b });
    }
    return out;
  }, [events, tasks, subtasksByTask, now]);

  // ---- 予定ブロックの長押しドラッグ（15分スナップ） ----
  const setDragBoth = (d: DragState | null) => {
    dragRef.current = d;
    setDrag(d);
  };
  const sourceIndex = (t: number) => Math.max(0, dayStarts.findIndex((d) => t >= d && t < addDays(d, 1)));
  const colWidth = () => (colsRef.current?.clientWidth ?? 300) / days;

  const onItemPointerDown = (e: RPointerEvent, item: Item) => {
    if (e.button !== 0 || dragRef.current) return;
    const d: DragState = { item, pointerId: e.pointerId, startX: e.clientX, startY: e.clientY, active: false, moved: false, deltaMin: 0, deltaDays: 0 };
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
      setDragBoth({ ...cur, active: true });
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
    const deltaMin = Math.round(dy / pxPerMin / SNAP_MIN) * SNAP_MIN;
    const src = sourceIndex(d.item.start);
    const deltaDays = days > 1 ? Math.min(days - 1 - src, Math.max(-src, Math.round(dx / colWidth()))) : 0;
    if (deltaMin !== d.deltaMin || deltaDays !== d.deltaDays || (!d.moved && Math.hypot(dx, dy) > 6)) {
      setDragBoth({ ...d, deltaMin, deltaDays, moved: d.moved || Math.hypot(dx, dy) > 6 });
    }
  };

  const finishDrag = (commit: boolean) => {
    window.clearTimeout(timerRef.current);
    const d = dragRef.current;
    setDragBoth(null);
    gestureLock.release('timeline-drag');
    if (!d || !d.active) return;
    suppressClick.current = true;
    window.setTimeout(() => (suppressClick.current = false), 50);
    const realId = d.item.kind === 'event' ? d.item.event.id : d.item.task.id;
    if (!commit) return;
    if (d.moved && (d.deltaMin !== 0 || d.deltaDays !== 0)) {
      const newStart = snapToStep(addDays(d.item.start, d.deltaDays) + d.deltaMin * MINUTE, SNAP_MIN);
      onMove(d.item.kind, realId, newStart);
    } else if (!d.moved) {
      onItemMenu(d.item.kind, realId);
    }
  };

  const onItemClick = (item: Item) => {
    if (suppressClick.current) return;
    if (item.kind === 'event') onOpenEvent(item.event.id);
    else onOpenTask(item.task.id);
  };

  const renderColumn = useCallback(
    (dayStart: number, colIndex: number) => {
      const dayItems = items.filter((it) => it.start < addDays(dayStart, 1) && it.end > dayStart);
      const delayedTasks = dayItems.filter((it): it is Extract<Item, { kind: 'task' }> => it.kind === 'task' && it.block.delayed);
      const normal = dayItems.filter((it) => !(it.kind === 'task' && it.block.delayed));
      const placed = layoutDay(normal, dayStart);
      const placedDelayed = layoutDay(delayedTasks, dayStart);
      const extensionWindows = delayedTasks.map((t) => ({ start: t.block.plannedEnd, end: Math.max(t.block.end, t.block.eta ?? 0) }));
      const isToday = isSameDay(dayStart, now);
      const nowMin = (now - startOfDay(now)) / MINUTE;

      const renderBlock = (p: (typeof placed)[number], overlay: boolean) => {
        const it = p.item;
        const dragging = drag?.active && drag.item.id === it.id;
        const greyed = !overlay && it.kind === 'event' && extensionWindows.some((w) => overlaps(w, it));
        const cal = it.kind === 'event' ? calendarById.get(it.event.calendarId) : it.task.calendarId ? calendarById.get(it.task.calendarId) : undefined;
        const color = it.kind === 'task' ? 'var(--blue)' : cal?.color ?? 'var(--blue)';
        const leftPct = overlay ? 0 : (p.column / p.columns) * 100;
        const widthPct = overlay ? 100 : 100 / p.columns;
        const title = it.kind === 'event' ? it.event.title : it.task.title;
        const timeText = `${formatHm(it.start)}〜${formatHm(it.kind === 'task' ? it.block.plannedEnd : it.end)}`;
        const heightPx = p.height * pxPerMin;
        const planEndOffset = it.kind === 'task' && it.block.delayed ? ((it.block.plannedEnd - Math.max(it.start, dayStart)) / MINUTE) * pxPerMin : null;
        const etaAt = it.kind === 'task' ? it.block.eta : null;
        const etaPx = etaAt != null && etaAt > it.end ? ((Math.min(etaAt, addDays(dayStart, 1)) - it.end) / MINUTE) * pxPerMin : 0;
        return (
          <button
            key={it.id}
            type="button"
            className={`tl-block ${it.kind} ${greyed ? 'greyed' : ''} ${overlay ? 'overlay' : ''} ${dragging ? 'lifted-ghost' : ''} ${it.kind === 'task' ? `st-${it.task.status}` : ''} ${p.clippedStart ? 'clip-start' : ''} ${p.clippedEnd ? 'clip-end' : ''}`}
            style={{
              top: p.top * pxPerMin,
              height: Math.max(18, heightPx - 2),
              left: `calc(${leftPct}% + 1px)`,
              width: `calc(${widthPct}% - 3px)`,
              ['--c' as string]: color,
            }}
            aria-label={`${it.kind === 'task' ? 'タスク' : '予定'} ${title}、${timeText}${it.kind === 'task' && it.block.delayed ? '、遅延中' : ''}`}
            data-testid={`tl-${it.id}`}
            data-day={colIndex}
            onPointerDown={(e) => onItemPointerDown(e, it)}
            onPointerMove={onItemPointerMove}
            onPointerUp={() => finishDrag(true)}
            onPointerCancel={() => finishDrag(false)}
            onClick={() => onItemClick(it)}
            onContextMenu={(e) => e.preventDefault()}
          >
            {planEndOffset != null && planEndOffset < heightPx && <span className="tl-overrun" style={{ top: Math.max(0, planEndOffset) }} aria-hidden />}
            <span className="tl-title">
              {it.kind === 'task' && <span className="tl-ticon">{it.task.icon}</span>}
              {title}
            </span>
            {heightPx > 34 && <span className="tl-time">{timeText}</span>}
            {etaPx > 0 && etaAt != null && (
              <span className="tl-eta" style={{ height: etaPx }} aria-label={`予測終了 ${formatHm(etaAt)}`}>
                <span className="tl-eta-label">予測 {formatHm(etaAt)}</span>
              </span>
            )}
          </button>
        );
      };

      return (
        <div className={`tl-col ${isToday ? 'today' : ''}`} key={dayStart} data-testid={`tl-col-${colIndex}`} data-date={dayStart}>
          {placed.map((p) => renderBlock(p, false))}
          {placedDelayed.map((p) => renderBlock(p, true))}
          {drag?.active && (() => {
            const it = drag.item;
            if (sourceIndex(it.start) + drag.deltaDays !== colIndex) return null;
            const ns = snapToStep(addDays(it.start, drag.deltaDays) + drag.deltaMin * MINUTE, SNAP_MIN);
            const dur = (it.kind === 'task' ? it.block.plannedEnd : it.end) - it.start;
            const top = ((ns - dayStart) / MINUTE) * pxPerMin;
            return (
              <div className="tl-block lifted" style={{ top, height: Math.max(18, (dur / MINUTE) * pxPerMin - 2), left: 1, width: 'calc(100% - 3px)', ['--c' as string]: it.kind === 'task' ? 'var(--blue)' : calendarById.get(it.event.calendarId)?.color ?? 'var(--blue)' }} aria-hidden>
                <span className="tl-title">{it.kind === 'event' ? it.event.title : it.task.title}</span>
                <span className="tl-time">{formatHm(ns)}〜{formatHm(ns + dur)}</span>
              </div>
            );
          })()}
          {isToday && (
            <div className="tl-now" style={{ top: nowMin * pxPerMin }} data-testid="now-line" aria-hidden>
              <span className="tl-now-dot" />
            </div>
          )}
        </div>
      );
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [items, now, pxPerMin, drag, calendarById, dayStarts],
  );

  const todayIdx = dayStarts.findIndex((d) => isSameDay(d, now));
  const nowMin = (now - startOfDay(now)) / MINUTE;
  const hours = Array.from({ length: 25 }, (_, h) => h);
  const gridClass = hourH >= 110 ? 'q' : hourH >= 70 ? 'h' : '';

  return (
    <div className="timeline" data-testid={testId} style={{ ['--hour' as string]: `${hourH}px` }}>
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
      <div className="tl-scroll" ref={scrollRef} data-testid={testId ? `${testId}-scroll` : undefined}>
        <div className="tl-canvas" style={{ height: 24 * hourH }}>
          <div className="tl-gutter" aria-hidden>
            {hours.map((h) => {
              const nearNow = todayIdx >= 0 && Math.abs(nowMin - h * 60) * pxPerMin < 14;
              return (
                <span key={h} className={`tl-hour ${nearNow ? 'faded' : ''}`} style={{ top: h * hourH }}>
                  {h === 24 ? '' : `${h}:00`}
                </span>
              );
            })}
            {todayIdx >= 0 && (
              <span className="tl-now-label" style={{ top: nowMin * pxPerMin }} data-testid="now-label">
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
