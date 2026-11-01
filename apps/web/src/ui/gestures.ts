import { useEffect, useRef } from 'react';
import { DRAG_SLOP, LONG_PRESS_MS } from './motion';

/**
 * 長押し → メニュー／動けばドラッグ、の共通状態機械（Q07・Q99）。
 * - 押してすぐ動いた：スクロール等とみなし何もしない
 * - LONG_PRESS_MS 静止：onLongPress（メニュー）
 * - 長押し後に DRAG_SLOP 以上動いた：onDragStart（メニューは閉じてドラッグへ）
 */
export interface LongPressHandlers {
  onLongPress: (p: { x: number; y: number; target: HTMLElement }) => void;
  onDragStart?: (p: { x: number; y: number; pointerId: number; target: HTMLElement }) => void;
  disabled?: boolean;
}

export function useLongPress(h: LongPressHandlers) {
  const st = useRef<{ x: number; y: number; id: number; timer: number; fired: boolean; target: HTMLElement } | null>(null);
  const hr = useRef(h);
  hr.current = h;
  const clear = () => {
    if (st.current) window.clearTimeout(st.current.timer);
    st.current = null;
  };
  useEffect(() => clear, []);
  return {
    onPointerDown: (e: React.PointerEvent<HTMLElement>) => {
      if (hr.current.disabled || e.button !== 0) return;
      const target = e.currentTarget;
      const s = { x: e.clientX, y: e.clientY, id: e.pointerId, fired: false, target, timer: 0 };
      s.timer = window.setTimeout(() => {
        if (st.current !== s) return;
        s.fired = true;
        hr.current.onLongPress({ x: s.x, y: s.y, target });
      }, LONG_PRESS_MS);
      st.current = s;
    },
    onPointerMove: (e: React.PointerEvent<HTMLElement>) => {
      const s = st.current;
      if (!s || e.pointerId !== s.id) return;
      const d = Math.hypot(e.clientX - s.x, e.clientY - s.y);
      if (!s.fired && d > DRAG_SLOP) clear();
      else if (s.fired && d > DRAG_SLOP && hr.current.onDragStart) {
        hr.current.onDragStart({ x: e.clientX, y: e.clientY, pointerId: e.pointerId, target: s.target });
        clear();
      }
    },
    onPointerUp: clear,
    onPointerCancel: clear,
    onContextMenu: (e: React.MouseEvent) => e.preventDefault(),
    /** 長押しで開いた直後のクリックを無視するために使う */
    consumedClick: () => st.current?.fired === true,
  };
}

/**
 * 画面の左端から右へのスワイプで戻る（Q05・Q98）。
 * 左端 20px 以内で始まり、横方向が優勢なときだけ反応する（日付スワイプ・縦スクロールと競合しない）。
 * 進み具合を onProgress(0..1) で返し、離した位置で確定／取り消し。
 */
export function useEdgeSwipeBack(ref: React.RefObject<HTMLElement | null>, onBack: () => void, onProgress?: (p: number) => void) {
  const cb = useRef({ onBack, onProgress });
  cb.current = { onBack, onProgress };
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    let s: { x: number; y: number; id: number; active: boolean } | null = null;
    const down = (e: PointerEvent) => {
      if (e.clientX > 20 || e.button !== 0) return;
      s = { x: e.clientX, y: e.clientY, id: e.pointerId, active: false };
    };
    const move = (e: PointerEvent) => {
      if (!s || e.pointerId !== s.id) return;
      const dx = e.clientX - s.x;
      const dy = e.clientY - s.y;
      if (!s.active) {
        if (Math.abs(dy) > 12 && Math.abs(dy) > Math.abs(dx)) { s = null; return; }
        if (dx > 12) { s.active = true; try { el.setPointerCapture(e.pointerId); } catch { /* noop */ } }
      }
      if (s.active) cb.current.onProgress?.(Math.max(0, Math.min(1, dx / el.clientWidth)));
    };
    const up = (e: PointerEvent) => {
      if (!s || e.pointerId !== s.id) return;
      const done = s.active && e.clientX - s.x > el.clientWidth * 0.35;
      const was = s.active;
      s = null;
      if (done) cb.current.onBack();
      else if (was) cb.current.onProgress?.(0);
    };
    el.addEventListener('pointerdown', down);
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', up);
    el.addEventListener('pointercancel', up);
    return () => {
      el.removeEventListener('pointerdown', down);
      el.removeEventListener('pointermove', move);
      el.removeEventListener('pointerup', up);
      el.removeEventListener('pointercancel', up);
    };
  }, [ref]);
}

/**
 * ガラス部品の「触れた位置の光」（Q03・Q100）。
 * 文書全体で1つの監視だけを置き、触れている .glass-i 要素に --gx/--gy（指の位置）と data-press を付ける。
 */
export function installGlassPointer(): () => void {
  let cur: HTMLElement | null = null;
  const set = (el: HTMLElement, e: PointerEvent) => {
    const r = el.getBoundingClientRect();
    el.style.setProperty('--gx', `${e.clientX - r.left}px`);
    el.style.setProperty('--gy', `${e.clientY - r.top}px`);
  };
  const down = (e: PointerEvent) => {
    const el = (e.target as Element | null)?.closest?.('.glass-i') as HTMLElement | null;
    if (!el || (el as HTMLButtonElement).disabled) return;
    cur = el;
    set(el, e);
    el.dataset.press = '1';
  };
  const move = (e: PointerEvent) => cur && set(cur, e);
  const up = () => {
    if (cur) delete cur.dataset.press;
    cur = null;
  };
  document.addEventListener('pointerdown', down, { passive: true });
  document.addEventListener('pointermove', move, { passive: true });
  document.addEventListener('pointerup', up, { passive: true });
  document.addEventListener('pointercancel', up, { passive: true });
  return () => {
    document.removeEventListener('pointerdown', down);
    document.removeEventListener('pointermove', move);
    document.removeEventListener('pointerup', up);
    document.removeEventListener('pointercancel', up);
  };
}
