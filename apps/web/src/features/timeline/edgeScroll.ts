/**
 * ドラッグ中に指が時間軸の上端・下端に近づいたときの自動スクロール量（px / フレーム）。
 * 端からの距離に比例して速くなり、端の外側まで出ても上限で止める。範囲外は 0。
 */
export const EDGE_ZONE = 56;
export const EDGE_MAX_SPEED = 14;

export function edgeScrollSpeed(y: number, top: number, bottom: number, zone = EDGE_ZONE, max = EDGE_MAX_SPEED): number {
  if (bottom - top < zone * 2.5) return 0; // 小さすぎる領域では誤って流れないよう使わない
  if (y < top + zone) return -Math.round(max * Math.min(1, (top + zone - y) / zone));
  if (y > bottom - zone) return Math.round(max * Math.min(1, (y - (bottom - zone)) / zone));
  return 0;
}

/** スクロール可能な残り量で速さを制限する（端に着いたら止める） */
export function clampScroll(speed: number, scrollTop: number, maxScroll: number): number {
  if (speed < 0) return Math.max(speed, -scrollTop);
  if (speed > 0) return Math.min(speed, Math.max(0, maxScroll - scrollTop));
  return 0;
}
