import { useRef, useState } from 'react';

/**
 * 縦一覧のドラッグ並べ替え（C32）。右端のハンドルから始め、離した位置で1回だけ確定する。
 * 範囲外へ離した・キャンセルされたときは元の順へ戻す。端に近づくと一覧を自動スクロールする。
 * キーボード代替：ハンドルにフォーカス → Space/Enter で開始 → 上下キーで移動 → Space/Enter で確定、Esc で取消。
 */
export function useDragReorder(ids: string[], commit: (ids: string[]) => void) {
  const [preview, setPreview] = useState<string[] | null>(null);
  const [active, setActive] = useState<string | null>(null);
  const kb = useRef<{ id: string; order: string[] } | null>(null);

  const startPointer = (e: React.PointerEvent<HTMLElement>, id: string) => {
    e.preventDefault();
    const list = (e.currentTarget.closest('[data-reorder-list]') as HTMLElement | null) ?? null;
    if (!list) return;
    const items = [...list.querySelectorAll<HTMLElement>('[data-reorder-id]')];
    const rects = items.map((x) => x.getBoundingClientRect());
    const from = ids.indexOf(id);
    const el = items[from];
    if (!el) return;
    const scroller = list.closest('.scroll-body') as HTMLElement | null;
    const s0 = scroller?.scrollTop ?? 0;
    const y0 = e.clientY;
    let to = from;
    let lastY = e.clientY;
    let raf = 0;
    setActive(id);
    el.classList.add('dragging');
    const place = () => {
      const dy = lastY - y0 + ((scroller?.scrollTop ?? 0) - s0);
      el.style.transform = `translateY(${dy}px)`;
      const cy = rects[from]!.top + rects[from]!.height / 2 + dy - ((scroller?.scrollTop ?? 0) - s0);
      const i = rects.findIndex((r) => cy < r.bottom);
      to = i === -1 ? ids.length - 1 : i;
    };
    const tick = () => {
      if (scroller && Math.abs(lastY - y0) > 8) {
        const r = scroller.getBoundingClientRect();
        const v = lastY < r.top + 48 ? -8 : lastY > r.bottom - 96 ? 8 : 0;
        if (v) { scroller.scrollTop += v; place(); }
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    const move = (ev: PointerEvent) => { lastY = ev.clientY; place(); };
    const end = (ok: boolean) => () => {
      cancelAnimationFrame(raf);
      window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); window.removeEventListener('pointercancel', cancel);
      el.classList.remove('dragging'); el.style.transform = '';
      setActive(null);
      if (!ok || to === from) return;
      const next = ids.filter((x) => x !== id);
      next.splice(to, 0, id);
      commit(next);
    };
    const up = end(true);
    const cancel = end(false);
    window.addEventListener('pointermove', move); window.addEventListener('pointerup', up); window.addEventListener('pointercancel', cancel);
  };

  const onKey = (e: React.KeyboardEvent, id: string) => {
    const k = kb.current;
    if (e.key === ' ' || e.key === 'Enter') {
      e.preventDefault();
      if (!k) { kb.current = { id, order: [...ids] }; setActive(id); setPreview([...ids]); }
      else { kb.current = null; setActive(null); setPreview(null); if (k.order.join() !== ids.join()) commit(k.order); }
      return;
    }
    if (!k) return;
    if (e.key === 'Escape') { e.preventDefault(); kb.current = null; setActive(null); setPreview(null); return; }
    if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      e.preventDefault();
      const i = k.order.indexOf(k.id);
      const j = i + (e.key === 'ArrowUp' ? -1 : 1);
      if (j < 0 || j >= k.order.length) return;
      const next = [...k.order];
      [next[i], next[j]] = [next[j]!, next[i]!];
      k.order = next;
      setPreview(next);
    }
  };

  return { order: preview ?? ids, active, startPointer, onKey };
}
