import { useEffect, useSyncExternalStore, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import { Icon, type IconName } from '../components/Icon';
import { SPRING } from './motion';

export interface CtxItem {
  label: string;
  icon?: IconName;
  destructive?: boolean;
  disabled?: boolean;
  onSelect: () => void;
}
interface CtxState {
  id: number;
  rect: { x: number; y: number; w: number; h: number };
  preview: ReactNode;
  items: (CtxItem | 'separator')[];
  label: string;
}

let state: CtxState | null = null;
let seq = 0;
const subs = new Set<() => void>();
const emit = () => subs.forEach((f) => f());

/** 長押しされたカードを浮かせ、近くに操作メニューを出す（Q07・Q28・Q99）。 */
export function openContextMenu(o: { anchor: HTMLElement; preview: ReactNode; items: (CtxItem | 'separator')[]; label: string }) {
  const r = o.anchor.getBoundingClientRect();
  state = { id: ++seq, rect: { x: r.left, y: r.top, w: r.width, h: r.height }, preview: o.preview, items: o.items, label: o.label };
  navigator.vibrate?.(8);
  emit();
}
export function closeContextMenu() {
  state = null;
  emit();
}
export const isContextMenuOpen = () => state != null;

export function ContextMenuHost() {
  const s = useSyncExternalStore((f) => (subs.add(f), () => subs.delete(f)), () => state);
  const reduce = useReducedMotion();
  useEffect(() => {
    if (!s) return;
    const k = (e: KeyboardEvent) => e.key === 'Escape' && closeContextMenu();
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [s]);

  let layout: { px: number; py: number; pw: number; ph: number; mx: number; my: number; origin: string } | null = null;
  if (s) {
    const vw = window.innerWidth;
    const vh = window.innerHeight;
    const menuW = 250;
    const rows = s.items.filter((i) => i !== 'separator').length;
    const menuH = rows * 46 + s.items.filter((i) => i === 'separator').length * 8;
    const pw = Math.min(s.rect.w, vw - 24);
    // 短い予定でもタイトルと時刻の2行が切れない高さを確保（F6）。長いカードは画面の35%まで
    const ph = Math.min(Math.max(s.rect.h, 76), Math.max(76, vh * 0.35));
    let px = Math.min(Math.max(12, s.rect.x), vw - 12 - pw);
    let py = s.rect.y;
    // メニューをカードの下に置けなければ上へ。どちらも足りなければカードを上へずらす（画面外へはみ出さない）
    const top = 12 + (parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--sat')) || 0);
    let my = py + ph + 10;
    let origin = 'top';
    if (my + menuH > vh - 12) {
      if (py - 10 - menuH >= top) { my = py - 10 - menuH; origin = 'bottom'; }
      else { py = Math.max(top, vh - 12 - menuH - 10 - ph); my = py + ph + 10; }
    }
    const mx = Math.min(Math.max(12, s.rect.x + (s.rect.x + s.rect.w / 2 > vw / 2 ? s.rect.w - menuW : 0)), vw - 12 - menuW);
    px = Math.max(12, px);
    layout = { px, py, pw, ph, mx, my, origin };
  }

  return createPortal(
    <AnimatePresence>
      {s && layout && (
        <motion.div key={s.id} className="ctx-layer" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: reduce ? 0.05 : 0.16 }} onPointerDown={(e) => e.target === e.currentTarget && closeContextMenu()}>
          <div className="ctx-dim" onClick={closeContextMenu} />
          <motion.div
            className="ctx-preview"
            aria-hidden
            style={{ left: layout.px, width: layout.pw, minHeight: layout.ph, maxHeight: Math.max(layout.ph, 160) }}
            initial={{ top: s.rect.y, scale: 1 }}
            animate={{ top: layout.py, scale: reduce ? 1 : 1.03 }}
            transition={reduce ? { duration: 0 } : SPRING.pop}
          >
            {s.preview}
          </motion.div>
          <motion.div
            role="menu"
            aria-label={s.label}
            className="ctx-menu glass"
            style={{ left: layout.mx, top: layout.my, transformOrigin: layout.origin }}
            initial={reduce ? { opacity: 0 } : { opacity: 0, scale: 0.7 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0, scale: reduce ? 1 : 0.9 }}
            transition={reduce ? { duration: 0.08 } : SPRING.pop}
          >
            {s.items.map((it, i) =>
              it === 'separator' ? <div key={i} className="ctx-sep" role="separator" /> : (
                <button key={i} type="button" role="menuitem" disabled={it.disabled} className={`ctx-item ${it.destructive ? 'destructive' : ''}`} onClick={() => { closeContextMenu(); it.onSelect(); }}>
                  <span>{it.label}</span>
                  {it.icon && <Icon name={it.icon} size={20} />}
                </button>
              ),
            )}
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>,
    document.body,
  );
}
