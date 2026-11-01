import { useEffect, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { SPRING } from './motion';

/**
 * 編集画面の中から開く小型のガラスシート（日付・時刻・繰り返し・アイコン等：Q67・Q73〜79）。
 * 開いている間の値は呼び出し側の一時状態。「完了」で確定、背景タップ・Esc は取り消し。
 */
export function Popup({ open, title, onClose, onDone, doneLabel = '完了', children, testId, tall }: { open: boolean; title: string; onClose: () => void; onDone?: () => void; doneLabel?: string; children: ReactNode; testId?: string; tall?: boolean }) {
  const reduce = useReducedMotion();
  useEffect(() => {
    if (!open) return;
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', k, true);
    return () => window.removeEventListener('keydown', k, true);
  }, [open, onClose]);
  return createPortal(
    <AnimatePresence>
      {open && (
        <div className="popup-layer">
          <motion.div className="popup-dim" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={onClose} />
          <motion.div
            className={`popup glass ${tall ? 'tall' : ''}`}
            role="dialog"
            aria-modal="true"
            aria-label={title}
            data-testid={testId}
            initial={reduce ? { opacity: 0 } : { y: '100%' }}
            animate={reduce ? { opacity: 1 } : { y: 0 }}
            exit={reduce ? { opacity: 0 } : { y: '100%' }}
            transition={reduce ? { duration: 0.1 } : SPRING.sheet}
          >
            <div className="popup-bar">
              <button type="button" className="bar-btn" onClick={onClose}>キャンセル</button>
              <div className="popup-title">{title}</div>
              {onDone ? <button type="button" className="gbtn-primary glass-i" onClick={onDone} data-testid={testId ? `${testId}-done` : undefined}>{doneLabel}</button> : <span />}
            </div>
            <div className="popup-body">{children}</div>
          </motion.div>
        </div>
      )}
    </AnimatePresence>,
    document.body,
  );
}
