import { useSyncExternalStore } from 'react';
import { createPortal } from 'react-dom';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';

/**
 * 削除の取り消し（Q39・Q41・Q97・Q101）。
 * 削除は約5秒待ってから確定する。待つ間は画面から隠し、「取り消す」で元に戻す。
 * サーバーは削除の印を優先するため、送信前に取り消せるよう確定を遅らせる（アプリを閉じた場合は削除されずに残る＝安全側）。
 */
const HOLD_MS = 5000;
interface Pending { key: string; label: string; commit: () => Promise<void> | void; timer: number }
let pending: Pending[] = [];
let hidden = new Set<string>();
const subs = new Set<() => void>();
const emit = () => { hidden = new Set(pending.map((p) => p.key)); subs.forEach((f) => f()); };

export function deleteWithUndo(key: string, label: string, commit: () => Promise<void> | void) {
  // 既に保留中の同じ対象は確定させてから入れ替える
  flushKey(key);
  const p: Pending = { key, label, commit, timer: 0 };
  p.timer = window.setTimeout(() => { pending = pending.filter((x) => x !== p); emit(); void p.commit(); }, HOLD_MS);
  pending = [...pending, p];
  emit();
}
function flushKey(key: string) {
  const p = pending.find((x) => x.key === key);
  if (!p) return;
  window.clearTimeout(p.timer);
  pending = pending.filter((x) => x !== p);
  void p.commit();
}
export function undoDelete(key: string) {
  const p = pending.find((x) => x.key === key);
  if (!p) return;
  window.clearTimeout(p.timer);
  pending = pending.filter((x) => x !== p);
  emit();
}
/** 画面から隠す対象（`task:<id>` など） */
export function usePendingDeletes(): Set<string> {
  return useSyncExternalStore((f) => (subs.add(f), () => subs.delete(f)), () => hidden);
}
/** テスト・終了時：保留中をすぐ確定する */
export function flushAllDeletes() {
  for (const p of [...pending]) flushKey(p.key);
  emit();
}

export function UndoHost() {
  const list = useSyncExternalStore((f) => (subs.add(f), () => subs.delete(f)), () => pending);
  const reduce = useReducedMotion();
  const last = list.at(-1);
  return createPortal(
    <div className="undo-layer" aria-live="polite">
      <AnimatePresence>
        {last && (
          <motion.div key={last.key} className="undo-bar glass" initial={{ opacity: 0, y: reduce ? 0 : 16 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: reduce ? 0 : 16 }} data-testid="undo-bar">
            <span className="undo-text">{last.label}を削除しました</span>
            <button type="button" className="undo-btn" onClick={() => undoDelete(last.key)} data-testid="undo-delete">取り消す</button>
          </motion.div>
        )}
      </AnimatePresence>
    </div>,
    document.body,
  );
}
