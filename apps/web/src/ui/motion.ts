/** 動きの共通定数（Q10・Q100）。各画面で値を作らず、ここから使う。 */
export const SPRING = {
  /** シート・パネル：自然に止まる（揺れない） */
  sheet: { type: 'spring', stiffness: 420, damping: 40, mass: 0.9 },
  /** タブの選択カプセル・小さな部品：わずかに弾む */
  capsule: { type: 'spring', stiffness: 520, damping: 34, mass: 0.7 },
  /** メニュー・浮遊カード */
  pop: { type: 'spring', stiffness: 560, damping: 36 },
  /** 数値・グラフの変化 */
  value: { type: 'spring', stiffness: 260, damping: 32 },
} as const;

export const DURATION = { tap: 0.12, fade: 0.18, reduced: 0.08 } as const;

/** 長押しの認識時間と、ドラッグとみなす移動量（Q99 の共通状態機械で使う） */
export const LONG_PRESS_MS = 420;
export const DRAG_SLOP = 8;
