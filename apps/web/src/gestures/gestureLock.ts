/**
 * 同時に1つのジェスチャーだけが主導権を持つための簡易ロック。
 * 長押しの進捗スライド・予定ドラッグ・境界ハンドルが有効な間は、日付の横スワイプを無効にする。
 */
let owner: string | null = null;

export const gestureLock = {
  acquire(id: string): boolean {
    if (owner && owner !== id) return false;
    owner = id;
    return true;
  },
  release(id: string) {
    if (owner === id) owner = null;
  },
  isHeldByOther(id: string): boolean {
    return owner != null && owner !== id;
  },
  get owner() {
    return owner;
  },
};

/** iOS Safari では touch-action を途中で変えられないため、非passiveの touchmove で必要時だけスクロールを止める */
export function blockTouchScrollWhile(el: HTMLElement, isActive: () => boolean): () => void {
  const onMove = (e: TouchEvent) => {
    if (isActive() && e.cancelable) e.preventDefault();
  };
  el.addEventListener('touchmove', onMove, { passive: false });
  return () => el.removeEventListener('touchmove', onMove);
}
