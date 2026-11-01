import { useRef, type ReactNode } from 'react';
import { animate, motion, useMotionValue, useReducedMotion } from 'motion/react';
import { Icon, type IconName } from '../components/Icon';
import { SPRING } from './motion';

export interface SwipeAction { label: string; icon: IconName; color: 'blue' | 'red' | 'green' | 'gray'; onAct: () => void }

const ACT_W = 76;

/**
 * 行の左右スワイプ（Q39・Q98）。左へ：右側の操作（編集・削除）。深く引くと先頭の操作を実行（削除）。
 * 右へ：左側の操作（完了）。縦スクロールが優勢なときは反応しない。VoiceOver 用には行の長押しメニュー等の代替を用意すること。
 */
export function SwipeRow({ children, right = [], left = [], testId }: { children: ReactNode; right?: SwipeAction[]; left?: SwipeAction[]; testId?: string }) {
  const x = useMotionValue(0);
  const reduce = useReducedMotion();
  const st = useRef<{ id: number; x0: number; y0: number; base: number; dir: 0 | 1 | -1 } | null>(null);
  const rowRef = useRef<HTMLDivElement>(null);
  const openW = { right: right.length * ACT_W, left: left.length * ACT_W };

  const settle = (to: number) => (reduce ? x.set(to) : void animate(x, to, SPRING.capsule));
  const down = (e: React.PointerEvent) => {
    if (e.button !== 0) return;
    st.current = { id: e.pointerId, x0: e.clientX, y0: e.clientY, base: x.get(), dir: 0 };
  };
  const move = (e: React.PointerEvent) => {
    const s = st.current;
    if (!s || e.pointerId !== s.id) return;
    const dx = e.clientX - s.x0;
    const dy = e.clientY - s.y0;
    if (s.dir === 0) {
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) { st.current = null; return; }
      if (Math.abs(dx) < 10) return;
      s.dir = dx < 0 ? -1 : 1;
      try { (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId); } catch { /* noop */ }
    }
    let v = s.base + dx;
    if (v < 0 && !right.length) v = 0;
    if (v > 0 && !left.length) v = 0;
    x.set(v);
  };
  const up = (e: React.PointerEvent) => {
    const s = st.current;
    if (!s || e.pointerId !== s.id) return;
    st.current = null;
    if (s.dir === 0) return;
    const v = x.get();
    const w = rowRef.current?.clientWidth ?? 360;
    if (v < -w * 0.6 && right[0]) { settle(0); right[0].onAct(); return; } // 深いスワイプ
    if (v > w * 0.45 && left[0]) { settle(0); left[0].onAct(); return; }
    if (v < -openW.right / 2) settle(-openW.right);
    else if (v > openW.left / 2) settle(openW.left);
    else settle(0);
  };
  const act = (a: SwipeAction) => { settle(0); a.onAct(); };

  return (
    <div className="swipe-row" ref={rowRef} data-testid={testId}>
      {left.length > 0 && (
        <div className="swipe-actions left" aria-hidden>
          {left.map((a) => <button key={a.label} type="button" tabIndex={-1} className={`swipe-act ${a.color}`} onClick={() => act(a)}><Icon name={a.icon} size={20} strokeWidth={2.2} />{a.label}</button>)}
        </div>
      )}
      {right.length > 0 && (
        <div className="swipe-actions right" aria-hidden>
          {right.map((a) => <button key={a.label} type="button" tabIndex={-1} className={`swipe-act ${a.color}`} onClick={() => act(a)}><Icon name={a.icon} size={20} strokeWidth={2.2} />{a.label}</button>)}
        </div>
      )}
      <motion.div className="swipe-content" style={{ x }} onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={() => { st.current = null; settle(0); }}>
        {children}
      </motion.div>
    </div>
  );
}
