import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { Icon, type IconName } from './Icon';
import { ExitSafeLayer } from './Overlays';

export interface MenuItem {
  label: string;
  icon?: IconName;
  checked?: boolean;
  destructive?: boolean;
  disabled?: boolean;
  onSelect: () => void;
}

interface Props {
  label: string;
  items: (MenuItem | 'separator')[];
  children: ReactNode;
  className?: string;
  testId?: string;
}

/** iOS のプルダウンメニュー風。ボタンの近くに展開し、外側タップで閉じる。 */
export function MenuButton({ label, items, children, className = 'nav-icon-btn', testId }: Props) {
  const [open, setOpen] = useState(false);
  const btnRef = useRef<HTMLButtonElement>(null);
  const [pos, setPos] = useState<{ top: number; right: number; left: number | null }>({ top: 0, right: 0, left: null });
  const reduce = useReducedMotion();

  useLayoutEffect(() => {
    if (!open || !btnRef.current) return;
    const r = btnRef.current.getBoundingClientRect();
    const vw = window.innerWidth;
    const right = Math.max(8, vw - r.right);
    setPos({ top: r.bottom + 6, right, left: r.left < vw / 3 ? Math.max(8, r.left) : null });
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && setOpen(false);
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open]);

  return (
    <>
      <button ref={btnRef} type="button" className={className} aria-label={label} aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen((o) => !o)} data-testid={testId}>
        {children}
      </button>
      {createPortal(
        <AnimatePresence>
          {open && (
            <ExitSafeLayer className="menu-layer" onPointerDown={(e) => e.target === e.currentTarget && setOpen(false)}>
              <motion.div
                role="menu"
                aria-label={label}
                className="menu"
                style={pos.left != null ? { top: pos.top, left: pos.left, transformOrigin: 'top left' } : { top: pos.top, right: pos.right, transformOrigin: 'top right' }}
                initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 0.6 }}
                animate={{ opacity: 1, scale: 1 }}
                exit={{ opacity: 0, scale: reduce ? 1 : 0.9 }}
                transition={reduce ? { duration: 0.1 } : { type: 'spring', stiffness: 520, damping: 36 }}
              >
                {items.map((it, i) =>
                  it === 'separator' ? (
                    <div key={i} className="menu-sep" role="separator" />
                  ) : (
                    <button
                      key={i}
                      type="button"
                      role={it.checked !== undefined ? 'menuitemradio' : 'menuitem'}
                      aria-checked={it.checked}
                      disabled={it.disabled}
                      className={`menu-item ${it.destructive ? 'destructive' : ''}`}
                      onClick={() => {
                        setOpen(false);
                        it.onSelect();
                      }}
                    >
                      <span className="menu-check">{it.checked ? <Icon name="check" size={17} strokeWidth={2.4} /> : null}</span>
                      <span className="menu-label">{it.label}</span>
                      {it.icon && <Icon name={it.icon} size={20} />}
                    </button>
                  ),
                )}
              </motion.div>
            </ExitSafeLayer>
          )}
        </AnimatePresence>,
        document.body,
      )}
    </>
  );
}
