import { useEffect, useRef, type RefObject } from 'react';
import { animate, type MotionValue } from 'motion/react';
import { gestureLock } from './gestureLock';

interface Options {
  /** 横移動量を反映するモーション値（コンテンツの translateX に結び付ける） */
  x: MotionValue<number>;
  /** +1 = 次（左へスワイプ）, -1 = 前 */
  onPage: (dir: 1 | -1) => void;
  enabled?: boolean;
  reduceMotion?: boolean;
}

const LOCK_ID = 'pager';

/**
 * 日付の横スワイプ。縦方向が先に優勢になったら何もしない（縦スクロールはブラウザに任せる）。
 * 要素側は `touch-action: pan-y` にしておくこと。
 */
export function usePager(ref: RefObject<HTMLElement | null>, { x, onPage, enabled = true, reduceMotion = false }: Options) {
  const onPageRef = useRef(onPage);
  onPageRef.current = onPage;

  useEffect(() => {
    const el = ref.current;
    if (!el || !enabled) return;
    let start: { x: number; y: number; t: number; id: number } | null = null;
    let axis: 'h' | 'v' | null = null;
    let suppressClick = false;

    const reset = () => {
      start = null;
      axis = null;
      gestureLock.release(LOCK_ID);
    };

    const down = (e: PointerEvent) => {
      if (e.button !== 0 || start) return;
      if ((e.target as HTMLElement).closest('[data-no-pager]')) return;
      start = { x: e.clientX, y: e.clientY, t: performance.now(), id: e.pointerId };
      axis = null;
    };
    const move = (e: PointerEvent) => {
      if (!start || e.pointerId !== start.id) return;
      if (gestureLock.isHeldByOther(LOCK_ID)) {
        if (axis === 'h') void animate(x, 0, { type: 'spring', stiffness: 500, damping: 45 });
        reset();
        return;
      }
      const dx = e.clientX - start.x;
      const dy = e.clientY - start.y;
      if (axis === null) {
        if (Math.abs(dx) > 10 && Math.abs(dx) > Math.abs(dy) * 1.3) {
          if (!gestureLock.acquire(LOCK_ID)) return reset();
          axis = 'h';
          try {
            el.setPointerCapture(e.pointerId);
          } catch {
            /* noop */
          }
        } else if (Math.abs(dy) > 10) {
          axis = 'v';
        }
      }
      if (axis === 'h') {
        x.set(dx);
        suppressClick = true;
      }
    };
    const up = (e: PointerEvent) => {
      if (!start || e.pointerId !== start.id) return;
      if (axis === 'h') {
        const dx = e.clientX - start.x;
        const v = dx / Math.max(1, performance.now() - start.t);
        const w = el.clientWidth || 1;
        if (Math.abs(dx) > w * 0.22 || (Math.abs(v) > 0.45 && Math.abs(dx) > 30)) {
          const dir: 1 | -1 = dx < 0 ? 1 : -1;
          if (reduceMotion) {
            x.set(0);
            onPageRef.current(dir);
          } else {
            void animate(x, -dir * w, { duration: 0.16, ease: 'easeIn' }).then(() => {
              onPageRef.current(dir);
              x.set(dir * w * 0.4);
              void animate(x, 0, { type: 'spring', stiffness: 420, damping: 42 });
            });
          }
        } else {
          void animate(x, 0, { type: 'spring', stiffness: 500, damping: 45 });
        }
      }
      reset();
    };
    const cancel = (e: PointerEvent) => {
      if (!start || e.pointerId !== start.id) return;
      if (axis === 'h') void animate(x, 0, { type: 'spring', stiffness: 500, damping: 45 });
      reset();
    };
    const click = (e: MouseEvent) => {
      if (suppressClick) {
        e.stopPropagation();
        e.preventDefault();
        suppressClick = false;
      }
    };
    const clearSuppress = () => {
      // 次のタップを妨げないよう、少し後に解除
      window.setTimeout(() => (suppressClick = false), 0);
    };

    el.addEventListener('pointerdown', down);
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', up);
    el.addEventListener('pointercancel', cancel);
    el.addEventListener('click', click, true);
    el.addEventListener('pointerup', clearSuppress);
    return () => {
      el.removeEventListener('pointerdown', down);
      el.removeEventListener('pointermove', move);
      el.removeEventListener('pointerup', up);
      el.removeEventListener('pointercancel', cancel);
      el.removeEventListener('click', click, true);
      el.removeEventListener('pointerup', clearSuppress);
      reset();
    };
  }, [ref, x, enabled, reduceMotion]);
}
