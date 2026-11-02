import { useCallback, useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { animate, motion, useDragControls, useMotionValue, useReducedMotion } from 'motion/react';
import { ExitSafeLayer } from './Overlays';
import { useUIActions } from '../app/ui';
import { SPRING } from '../ui/motion';

export type Detent = 'small' | 'medium' | 'large';

interface SheetProps {
  title?: ReactNode;
  left?: ReactNode;
  right?: ReactNode;
  onClose: () => void;
  children: ReactNode;
  /** 何段目のシートか（重ねたときに奥を少し縮める） */
  depth?: number;
  labelledBy?: string;
  /** 最初の大きさ（Q06）。small=内容に合わせた小型、medium=約半分、large=ほぼ全画面 */
  detent?: Detent;
  /** 上下スワイプで移れる大きさ。省略時は detent だけ */
  detents?: Detent[];
  /** 未保存の変更がある：閉じる操作（下スワイプ・背景・Esc）で確認を出す（Q06・Q71） */
  dirty?: boolean;
  /** 下部に固定する部品（編集画面の下部タブなど） */
  footer?: ReactNode;
  className?: string;
  testId?: string;
}

const ORDER: Detent[] = ['small', 'medium', 'large'];

/**
 * iOS 風のボトムシート（共通基盤）。
 * 上部のハンドル領域だけで上下にドラッグし、本文のスクロール・入力と競合しない。
 * 上へ：大きく、下へ：小さく → 閉じる。未保存なら閉じる前に確認する。
 */
export function Sheet({ title, left, right, onClose, children, depth = 0, labelledBy, detent = 'large', detents, dirty = false, footer, className = '', testId }: SheetProps) {
  const controls = useDragControls();
  const reduce = useReducedMotion();
  const { confirm } = useUIActions();
  const panelRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);
  const allowed = (detents ?? [detent]).slice().sort((a, b) => ORDER.indexOf(a) - ORDER.indexOf(b));
  const [current, setCurrent] = useState<Detent>(detent);
  const [panelH, setPanelH] = useState(0);
  const [smallH, setSmallH] = useState(0);
  const y = useMotionValue(0);
  const dirtyRef = useRef(dirty);
  dirtyRef.current = dirty;
  const closing = useRef(false);

  useLayoutEffect(() => {
    const el = panelRef.current;
    if (!el) return;
    const measure = () => {
      setPanelH(el.clientHeight);
      const head = el.querySelector('.sheet-head') as HTMLElement | null;
      const body = contentRef.current;
      setSmallH(Math.min(el.clientHeight, (head?.offsetHeight ?? 60) + (body?.scrollHeight ?? 200) + 12));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    if (contentRef.current) ro.observe(contentRef.current);
    return () => ro.disconnect();
  }, []);

  const offsetFor = useCallback((d: Detent) => {
    if (!panelH) return 0;
    if (d === 'large') return 0;
    if (d === 'medium') return Math.round(panelH * 0.42);
    return Math.max(0, panelH - smallH);
  }, [panelH, smallH]);

  // 大きさの変化（測定・段の変更）に合わせて位置を合わせる
  useEffect(() => {
    if (closing.current) return;
    const to = offsetFor(current);
    if (reduce) y.set(to);
    else void animate(y, to, SPRING.sheet);
  }, [current, offsetFor, reduce, y]);

  const requestClose = useCallback(async () => {
    if (closing.current) return;
    if (dirtyRef.current) {
      void animate(y, offsetFor(current), SPRING.sheet);
      const discard = await confirm({ title: '変更を破棄しますか？', message: '保存していない変更があります。', confirmLabel: '変更を破棄', cancelLabel: '編集を続ける', destructive: true });
      if (!discard) return;
    }
    closing.current = true;
    onClose();
  }, [confirm, current, offsetFor, onClose, y]);

  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    panelRef.current?.focus();
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && void requestClose();
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('keydown', onKey);
      prev?.focus?.();
    };
  }, [requestClose]);

  const onDragEnd = (_: unknown, info: { offset: { y: number }; velocity: { y: number } }) => {
    const pos = y.get();
    const idx = allowed.indexOf(current);
    const fast = Math.abs(info.velocity.y) > 700;
    if (info.velocity.y > 700 || pos - offsetFor(allowed[0]!) > 110) {
      // 一番小さい段より下：閉じる（大きい段からの速いスワイプは1段ずつ）
      if (fast && idx > 0 && info.offset.y < panelH * 0.5) return setCurrent(allowed[idx - 1]!), void animate(y, offsetFor(allowed[idx - 1]!), SPRING.sheet);
      return void requestClose();
    }
    // いちばん近い段へ
    let best = current;
    let bestD = Infinity;
    for (const d of allowed) {
      const dd = Math.abs(offsetFor(d) - pos) - (fast && Math.sign(offsetFor(d) - offsetFor(current)) === Math.sign(info.velocity.y) ? panelH : 0);
      if (dd < bestD) { bestD = dd; best = d; }
    }
    setCurrent(best);
    void animate(y, offsetFor(best), SPRING.sheet);
  };

  return (
    <ExitSafeLayer className="sheet-layer" style={{ zIndex: 50 + depth * 2 }}>
      <motion.div className="sheet-dim" initial={{ opacity: 0 }} animate={{ opacity: current === 'large' ? 1 : 0.55 }} exit={{ opacity: 0 }} transition={{ duration: reduce ? 0 : 0.22 }} onClick={() => void requestClose()} />
      <motion.div
        className="sheet-slide"
        initial={reduce ? { opacity: 0 } : { y: '100%' }}
        animate={reduce ? { opacity: 1 } : { y: '0%' }}
        exit={reduce ? { opacity: 0 } : { y: '100%' }}
        transition={reduce ? { duration: 0.12 } : SPRING.sheet}
      >
      <motion.div
        ref={panelRef}
        className={`sheet glass-sheet ${className}`}
        data-detent={current}
        data-testid={testId}
        role="dialog"
        aria-modal="true"
        aria-labelledby={labelledBy}
        tabIndex={-1}
        style={{ y }}
        drag="y"
        dragListener={false}
        dragControls={controls}
        dragConstraints={{ top: 0, bottom: panelH || 800 }}
        dragElastic={{ top: 0.08, bottom: 0.6 }}
        dragMomentum={false}
        onDragEnd={onDragEnd}
      >
        <div className="sheet-head" onPointerDown={(e) => { if (!(e.target as Element).closest('button, input, select, textarea, a')) controls.start(e); }}>
          <div className="sheet-grabber" aria-hidden />
          <div className="sheet-bar">
            <div className="sheet-bar-side">{left}</div>
            <div className="sheet-title" id={labelledBy}>
              {title}
            </div>
            <div className="sheet-bar-side right">{right}</div>
          </div>
          {allowed.length > 1 && (
            <button type="button" className="sr-only" onClick={() => setCurrent(current === 'large' ? allowed[0]! : 'large')}>
              {current === 'large' ? 'シートを小さくする' : 'シートを大きくする'}
            </button>
          )}
        </div>
        <div className="sheet-body" ref={contentRef} style={current !== 'large' && panelH ? { paddingBottom: offsetFor(current) + 28 } : undefined}>{children}</div>
        {footer && <div className="sheet-footer" style={current !== 'large' && panelH ? { transform: `translateY(${-offsetFor(current)}px)` } : undefined}>{footer}</div>}
      </motion.div>
      </motion.div>
    </ExitSafeLayer>
  );
}
