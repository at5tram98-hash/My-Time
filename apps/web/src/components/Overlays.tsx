import type { CSSProperties, PointerEvent as ReactPointerEvent, ReactNode } from 'react';
import { AnimatePresence, motion, useIsPresent, useReducedMotion } from 'motion/react';
import { useUI } from '../app/ui';

/** iOS風アラート／アクションシート（確認なしの破壊的操作をしないための共通部品） */
export function AlertHost() {
  const { alert } = useUI();
  const reduce = useReducedMotion();
  return (
    <AnimatePresence>
      {alert && (
        <ExitSafeLayer className="alert-layer" key={alert.id}>
          <motion.div className="sheet-dim" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} onClick={() => alert.variant === 'sheet' && alert.resolve(null)} />
          {alert.variant === 'alert' ? (
            <motion.div
              className="alert"
              role="alertdialog"
              aria-modal="true"
              aria-labelledby="alert-title"
              initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 1.12 }}
              animate={{ opacity: 1, scale: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: reduce ? 0.01 : 0.2 }}
            >
              <div className="alert-text">
                <div className="alert-title" id="alert-title">
                  {alert.title}
                </div>
                {alert.message && <div className="alert-message">{alert.message}</div>}
              </div>
              <div className={`alert-buttons ${alert.buttons.length > 2 ? 'stack' : ''}`}>
                {alert.buttons.map((b, i) => (
                  <button
                    key={i}
                    type="button"
                    className={`alert-btn ${b.style ?? ''}`}
                    autoFocus={b.style === 'cancel'}
                    onClick={() => alert.resolve(b.value)}
                  >
                    {b.label}
                  </button>
                ))}
              </div>
            </motion.div>
          ) : (
            <motion.div
              className="action-sheet"
              role="dialog"
              aria-modal="true"
              aria-label={alert.title}
              initial={reduce ? { opacity: 0 } : { y: '110%' }}
              animate={reduce ? { opacity: 1 } : { y: 0 }}
              exit={reduce ? { opacity: 0 } : { y: '110%' }}
              transition={{ type: 'spring', stiffness: 460, damping: 42 }}
            >
              <div className="action-group">
                <div className="action-head">
                  <div className="action-title">{alert.title}</div>
                  {alert.message && <div className="action-message">{alert.message}</div>}
                </div>
                {alert.buttons.map((b, i) => (
                  <button key={i} type="button" className={`action-btn ${b.style ?? ''}`} onClick={() => alert.resolve(b.value)}>
                    {b.label}
                  </button>
                ))}
              </div>
              <button type="button" className="action-btn cancel action-cancel" autoFocus onClick={() => alert.resolve(null)}>
                キャンセル
              </button>
            </motion.div>
          )}
        </ExitSafeLayer>
      )}
    </AnimatePresence>
  );
}

/** 閉じるアニメーション中は操作を受け付けない（次のタップを透過させる） */
export function ExitSafeLayer({ className, children, style, onPointerDown }: { className: string; children: ReactNode; style?: CSSProperties; onPointerDown?: (e: ReactPointerEvent<HTMLDivElement>) => void }) {
  const present = useIsPresent();
  return (
    <div className={className} onPointerDown={onPointerDown} style={{ ...style, pointerEvents: present ? undefined : 'none' }} {...(present ? {} : { inert: '', 'aria-hidden': true })}>
      {children}
    </div>
  );
}

export function ToastHost() {
  const { toast } = useUI();
  return (
    <div className="toast-layer" aria-live="polite">
      <AnimatePresence>
        {toast && (
          <motion.div className="toast" initial={{ opacity: 0, y: -12 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: -12 }} transition={{ duration: 0.2 }}>
            {toast}
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
