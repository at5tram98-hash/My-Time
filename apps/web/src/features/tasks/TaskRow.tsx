import { useEffect, useRef, useState, type PointerEvent as RPointerEvent } from 'react';
import { motion, useReducedMotion } from 'motion/react';
import {
  actualProgress, canScrubProgress, delayInfo, formatDayLabel, formatHm, idealProgress, rowTimeLabel, type Subtask, type Task,
} from '@my-time/domain';
import { TaskIcon } from '../../components/TaskIcon';
import { Icon } from '../../components/Icon';
import { useUI } from '../../app/ui';
import { repo } from '../../data/repo';
import { blockTouchScrollWhile, gestureLock } from '../../gestures/gestureLock';

const LONG_PRESS_MS = 380;

interface Props {
  task: Task;
  subtasks: Subtask[];
  now: number;
  showDate?: boolean;
}

type Mode = { kind: 'idle' } | { kind: 'scrub'; value: number; initial: number; dragged: boolean };

export function TaskRow({ task, subtasks, now, showDate }: Props) {
  const { openSheet, confirm, showToast } = useUI();
  const reduce = useReducedMotion();
  const rowRef = useRef<HTMLDivElement>(null);
  const barRef = useRef<HTMLDivElement>(null);
  const [mode, setMode] = useState<Mode>({ kind: 'idle' });
  const modeRef = useRef<Mode>(mode);
  const press = useRef<{ x: number; y: number; id: number; timer: number } | null>(null);
  const suppressClick = useRef(false);
  const [shake, setShake] = useState(false);
  const lockId = `row-${task.id}`;

  const setModeBoth = (m: Mode) => {
    modeRef.current = m;
    setMode(m);
  };

  useEffect(() => {
    const el = rowRef.current;
    if (!el) return;
    return blockTouchScrollWhile(el, () => modeRef.current.kind === 'scrub');
  }, []);

  useEffect(() => () => gestureLock.release(lockId), [lockId]);

  const label = rowTimeLabel(task, subtasks, now);
  const delay = delayInfo(task, now);
  const ap = actualProgress(task, subtasks);

  const activate = () => {
    const p = press.current;
    if (!p) return;
    if (task.kind !== 'do' || task.status === 'done') return;
    if (!canScrubProgress(task, subtasks)) {
      setShake(true);
      window.setTimeout(() => setShake(false), 400);
      showToast('サブタスクの完了数から自動で計算されます');
      suppressClick.current = true;
      return;
    }
    if (!gestureLock.acquire(lockId)) return;
    try {
      rowRef.current?.setPointerCapture(p.id);
    } catch {
      /* noop */
    }
    navigator.vibrate?.(10);
    // 初期値は理想進捗率（仕様 §2）。予定時刻がないタスクだけ、既存の実績（なければ0%）から始める
    const init = idealProgress(task, now) ?? ap.value ?? 0;
    suppressClick.current = true;
    setModeBoth({ kind: 'scrub', value: init, initial: init, dragged: false });
  };

  const onPointerDown = (e: RPointerEvent) => {
    if (e.button !== 0 || press.current) return;
    if ((e.target as HTMLElement).closest('[data-row-control]')) return;
    suppressClick.current = false;
    press.current = { x: e.clientX, y: e.clientY, id: e.pointerId, timer: window.setTimeout(activate, LONG_PRESS_MS) };
  };

  const onPointerMove = (e: RPointerEvent) => {
    const p = press.current;
    if (!p || e.pointerId !== p.id) return;
    const dx = e.clientX - p.x;
    const dy = e.clientY - p.y;
    const m = modeRef.current;
    if (m.kind !== 'scrub') {
      if (Math.hypot(dx, dy) > 8) {
        window.clearTimeout(p.timer);
        press.current = null;
      }
      return;
    }
    // 指の横移動量をバーの幅に対して1:1で反映（充填の端が指と同じ距離だけ動く）
    // 浮いたセルの拡大率（scale）も含めた、画面上の実際のバー幅で割る
    const row = rowRef.current;
    const rowScale = row && row.clientWidth > 0 ? row.getBoundingClientRect().width / row.clientWidth : 1;
    const width = (barRef.current?.clientWidth ?? Math.max(1, (row?.clientWidth ?? 320) - 24)) * rowScale;
    const v = Math.min(1, Math.max(0, m.initial + dx / width));
    const dragged = m.dragged || Math.abs(dx) > 4;
    if ((v >= 1 && m.value < 1) || (v <= 0 && m.value > 0)) navigator.vibrate?.(6);
    setModeBoth({ ...m, value: v, dragged });
  };

  const end = async (commit: boolean) => {
    const p = press.current;
    if (p) window.clearTimeout(p.timer);
    press.current = null;
    const m = modeRef.current;
    setModeBoth({ kind: 'idle' });
    gestureLock.release(lockId);
    if (m.kind !== 'scrub' || !commit || !m.dragged) return; // ドラッグなしの長押し・キャンセルは記録しない
    try {
      if (m.value >= 0.995) {
        const ok = await confirm({ title: '終了しますか？', message: `「${task.title}」を100%で終了します。`, confirmLabel: '終了' });
        if (ok) {
          await repo.completeFromProgress(task.id);
          showToast('終了しました');
        }
      } else {
        await repo.recordProgress(task.id, m.value);
      }
    } catch (err) {
      showToast(err instanceof Error ? err.message : '保存できませんでした');
    }
  };

  const onClick = () => {
    if (suppressClick.current) {
      suppressClick.current = false;
      return;
    }
    openSheet({ kind: 'task', id: task.id });
  };

  const scrubbing = mode.kind === 'scrub';
  const pct = scrubbing ? Math.round(mode.value * 100) : 0;
  const timeText = label.kind === 'none' ? '' : formatHm(label.at);
  const timeTag = label.kind === 'eta' ? '予測' : label.kind === 'plannedEnd' ? '予定' : label.kind === 'actualEnd' ? '完了' : '';

  return (
    <div
      ref={rowRef}
      className={`task-row ${scrubbing ? 'scrubbing' : ''} ${shake ? 'shake' : ''} ${task.status === 'done' ? 'done' : ''}`}
      data-testid={`task-row-${task.id}`}
      data-task-title={task.title}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={() => void end(true)}
      onPointerCancel={() => void end(false)}
      onContextMenu={(e) => e.preventDefault()}
    >
      <button type="button" className="task-row-main" onClick={onClick} aria-label={`${task.title}${delay.delayed ? `、${delay.overMinutes}分遅延` : ''}${ap.value != null ? `、実績${Math.round(ap.value * 100)}%` : ''}。タップで詳細${task.kind === 'do' ? '、長押しで進捗入力' : ''}`}>
        {task.kind === 'check' ? (
          <span
            role="checkbox"
            aria-checked={task.checked}
            aria-label={`${task.title}をチェック`}
            tabIndex={0}
            data-row-control
            className={`check-circle ${task.checked ? 'on' : ''}`}
            onClick={(e) => {
              e.stopPropagation();
              void repo.toggleCheck(task.id);
            }}
            onKeyDown={(e) => {
              if (e.key === ' ' || e.key === 'Enter') {
                e.preventDefault();
                e.stopPropagation();
                void repo.toggleCheck(task.id);
              }
            }}
          >
            {task.checked ? <Icon name="check" size={16} strokeWidth={3} /> : <span className="check-emoji">{task.icon}</span>}
          </span>
        ) : (
          <TaskIcon task={task} now={now} />
        )}
        <span className="task-row-text">
          <span className="task-row-title">
            {task.title}
            {task.autoReserved && <span className="ar-badge" aria-label="自動予約">AR</span>}
          </span>
          <span className="task-row-sub">
            {showDate && (task.plannedStart ?? task.checkAt) != null ? `${formatDayLabel((task.plannedStart ?? task.checkAt)!)} ` : ''}
            {task.status === 'running' ? <span className="running-dot">実行中</span> : task.status === 'paused' ? '一時停止中' : task.category ?? (task.kind === 'check' ? '確認' : '')}
            {ap.value != null && task.status !== 'done' ? ` · ${Math.round(ap.value * 100)}%` : ''}
            {subtasks.length > 0 ? ` · ${subtasks.filter((s) => s.done).length}/${subtasks.length}` : ''}
          </span>
        </span>
        <span className={`task-row-time ${label.kind} ${delay.delayed ? 'late' : ''} ${delay.delayed && !reduce ? 'blink' : ''}`}>
          {timeTag && <span className="time-tag">{timeTag}</span>}
          <span className="time-val">{timeText}</span>
          {delay.delayed && <span className="late-text">+{delay.overMinutes}分</span>}
        </span>
      </button>
      {scrubbing && (
        <motion.div
          ref={barRef}
          className="scrubber"
          role="slider"
          aria-label={`${task.title}の実績進捗`}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-valuenow={pct}
          data-value={scrubbing ? mode.value.toFixed(4) : undefined}
          data-testid="progress-scrubber"
          initial={reduce ? { opacity: 0 } : { opacity: 0, scaleX: 0.55, scaleY: 0.8 }}
          animate={{ opacity: 1, scaleX: 1, scaleY: 1 }}
          transition={reduce ? { duration: 0.08 } : { type: 'spring', stiffness: 520, damping: 34 }}
        >
          <div className="scrub-fill" style={{ width: `${Math.max(pct, 0)}%` }}>
            {pct >= 18 && (
              <span className="scrub-num">
                {pct}
                <small>%</small>
              </span>
            )}
          </div>
          {pct < 18 && (
            <span className="scrub-num outside" style={{ left: `calc(${pct}% + 12px)` }}>
              {pct}
              <small>%</small>
            </span>
          )}
        </motion.div>
      )}
    </div>
  );
}
