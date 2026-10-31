import { useEffect, useRef, type ReactNode } from 'react';
import { motion, useDragControls, useReducedMotion } from 'motion/react';
import { ExitSafeLayer } from './Overlays';

interface SheetProps {
  title?: ReactNode;
  left?: ReactNode;
  right?: ReactNode;
  onClose: () => void;
  children: ReactNode;
  /** 何段目のシートか（重ねたときに奥を少し縮める） */
  depth?: number;
  labelledBy?: string;
}

const SPRING = { type: 'spring', stiffness: 420, damping: 40, mass: 0.9 } as const;

/** iOS風のボトムシート。グラバー/ヘッダーを下へドラッグ、または背景タップで閉じる。 */
export function Sheet({ title, left, right, onClose, children, depth = 0, labelledBy }: SheetProps) {
  const controls = useDragControls();
  const reduce = useReducedMotion();
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    panelRef.current?.focus();
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', onKey);
    return () => {
      window.removeEventListener('keydown', onKey);
      prev?.focus?.();
    };
  }, [onClose]);

  return (
    <ExitSafeLayer className="sheet-layer" style={{ zIndex: 50 + depth * 2 }}>
      <motion.div
        className="sheet-dim"
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        exit={{ opacity: 0 }}
        transition={{ duration: reduce ? 0 : 0.22 }}
        onClick={onClose}
      />
      <motion.div
        ref={panelRef}
        className="sheet"
        role="dialog"
        aria-modal="true"
        aria-labelledby={labelledBy}
        tabIndex={-1}
        initial={reduce ? { opacity: 0 } : { y: '100%' }}
        animate={reduce ? { opacity: 1 } : { y: 0 }}
        exit={reduce ? { opacity: 0 } : { y: '100%' }}
        transition={reduce ? { duration: 0.12 } : SPRING}
        drag="y"
        dragListener={false}
        dragControls={controls}
        dragConstraints={{ top: 0, bottom: 0 }}
        dragElastic={{ top: 0.05, bottom: 0.9 }}
        onDragEnd={(_, info) => {
          if (info.offset.y > 120 || info.velocity.y > 600) onClose();
        }}
      >
        <div className="sheet-head" onPointerDown={(e) => controls.start(e)}>
          <div className="sheet-grabber" aria-hidden />
          <div className="sheet-bar">
            <div className="sheet-bar-side">{left}</div>
            <div className="sheet-title" id={labelledBy}>
              {title}
            </div>
            <div className="sheet-bar-side right">{right}</div>
          </div>
        </div>
        <div className="sheet-body">{children}</div>
      </motion.div>
    </ExitSafeLayer>
  );
}
