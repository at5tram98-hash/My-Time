import { useRef, useState } from 'react';
import { Icon, type IconName } from '../components/Icon';
import type { TabId } from '../app/ui';

export interface TabDef { id: TabId; label: string; icon: IconName }

/**
 * 下部タブ（Q01・Q04・Q100）。
 * - タップで選択。指を横に滑らせるとカプセルが指に追従し、離した位置のタブへ一度だけ切り替える。
 * - 途中で画面は切り替えない。縦方向へ外れた・キャンセルされた場合は元のタブへ戻す。
 * - キーボード・VoiceOver は通常のボタンとして操作できる（aria-current）。
 */
export function TabBar({ tabs, current, onSelect, badge }: { tabs: TabDef[]; current: TabId; onSelect: (t: TabId) => void; badge?: (t: TabId) => React.ReactNode }) {
  const glass = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState<{ x: number; idx: number } | null>(null);
  const st = useRef<{ id: number; x0: number; y0: number; moved: boolean } | null>(null);
  const curIdx = Math.max(0, tabs.findIndex((t) => t.id === current));

  const geom = () => {
    const el = glass.current!;
    const r = el.getBoundingClientRect();
    const pad = 5;
    const w = (r.width - pad * 2) / tabs.length;
    return { r, pad, w };
  };
  const idxAt = (clientX: number) => {
    const { r, pad, w } = geom();
    return Math.min(tabs.length - 1, Math.max(0, Math.floor((clientX - r.left - pad) / w)));
  };

  // 滑らせて選んだ直後に届く click（指を置いたタブ宛て）で選択を上書きしない
  const suppressClick = useRef(false);
  const onDown = (e: React.PointerEvent) => {
    if (e.button !== 0) return;
    suppressClick.current = false;
    st.current = { id: e.pointerId, x0: e.clientX, y0: e.clientY, moved: false };
  };
  const onMove = (e: React.PointerEvent) => {
    const s = st.current;
    if (!s || e.pointerId !== s.id) return;
    const dx = e.clientX - s.x0;
    if (!s.moved) {
      if (Math.abs(e.clientY - s.y0) > 24 && Math.abs(e.clientY - s.y0) > Math.abs(dx)) { st.current = null; return; }
      if (Math.abs(dx) < 6) return;
      s.moved = true;
      try { glass.current?.setPointerCapture(e.pointerId); } catch { /* noop */ }
    }
    const { r, pad, w } = geom();
    const x = Math.min(r.width - pad - w, Math.max(pad, e.clientX - r.left - w / 2)) - pad;
    setDrag({ x, idx: idxAt(e.clientX) });
  };
  const end = (commit: boolean) => (e: React.PointerEvent) => {
    const s = st.current;
    if (!s || e.pointerId !== s.id) return;
    st.current = null;
    if (s.moved) {
      suppressClick.current = true;
      window.setTimeout(() => { suppressClick.current = false; }, 400);
      const idx = idxAt(e.clientX);
      setDrag(null);
      if (commit && tabs[idx] && tabs[idx]!.id !== current) onSelect(tabs[idx]!.id);
    }
  };

  const shownIdx = drag?.idx ?? curIdx;
  return (
    <nav className="tabbar" aria-label="タブ" data-testid="tabbar">
      <div
        ref={glass}
        className={`tabbar-glass ${drag ? 'dragging' : ''}`}
        style={{ ['--tab-index' as string]: curIdx, ...(drag ? { ['--drag-x' as string]: `${drag.x}px` } : {}) }}
        onPointerDown={onDown}
        onPointerMove={onMove}
        onPointerUp={end(true)}
        onPointerCancel={end(false)}
        // タッチでは押したボタンが暗黙にキャプチャを持ち、ガラスへ移すときに子の lostpointercapture が届く。ガラス自身のものだけ扱う
        onLostPointerCapture={(e) => { if (e.target !== e.currentTarget) return; st.current = null; setDrag(null); }}
      >
        <span className="tab-capsule" aria-hidden />
        {tabs.map((t, i) => {
          const on = current === t.id;
          const hot = shownIdx === i;
          return (
            <button
              key={t.id}
              type="button"
              className={`tab ${on ? 'active' : ''} ${hot ? 'hot' : ''}`}
              aria-current={on ? 'page' : undefined}
              onClick={() => { if (suppressClick.current) { suppressClick.current = false; return; } if (!st.current?.moved) onSelect(t.id); }}
              data-testid={`tab-${t.id}`}
            >
              <span className="tab-icon">
                <Icon name={t.icon} size={24} strokeWidth={hot ? 2.2 : 1.8} filled={hot} />
                {badge?.(t.id)}
              </span>
              <span className="tab-label">{t.label}</span>
            </button>
          );
        })}
      </div>
    </nav>
  );
}
