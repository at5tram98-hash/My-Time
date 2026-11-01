/**
 * ユーザーが選ぶアイコン（タスク・カレンダー）の安定 ID と、旧形式（絵文字）からの対応。
 *
 * 保存形式：`Task.icon` / `Calendar.icon` は文字列のまま（schema 変更なし）。
 * - 新しく選んだ値は下の ID（英小文字）を保存する。
 * - 旧レコード・旧バックアップ・旧移行ファイルの絵文字は、表示時に `resolveItemIcon()` で ID へ読み替える。
 *   保存値そのものは書き換えない（一括更新・同期の大量発生を避け、元の値を失わない）。
 * - 未知の値は既定のアイコン（circle）で表示し、保存値はそのまま残す。
 */
export const ITEM_ICONS = {
  book: '本',
  pencil: '鉛筆',
  laptop: 'パソコン',
  note: 'メモ',
  books: '参考書',
  flask: '実験',
  target: '目標',
  briefcase: '仕事',
  run: '運動',
  sparkles: '掃除',
  cart: '買い物',
  pan: '料理',
  headphones: '音楽を聴く',
  chat: '会話',
  bulb: 'アイデア',
  star: '大切',
  calendar: '予定',
  graduation: '学校',
  house: '家',
  heart: '好きなこと',
  music: '音楽',
  plane: '旅行',
  dining: '食事',
  person: '人',
  circle: 'その他',
} as const;

export type ItemIconId = keyof typeof ITEM_ICONS;

/** タスクのアイコン選択に並べる順 */
export const TASK_ICON_CHOICES: readonly ItemIconId[] = ['book', 'pencil', 'laptop', 'note', 'books', 'flask', 'target', 'briefcase', 'run', 'sparkles', 'cart', 'pan', 'headphones', 'chat', 'bulb', 'star'];
/** カレンダーのアイコン選択に並べる順 */
export const CALENDAR_ICON_CHOICES: readonly ItemIconId[] = ['calendar', 'graduation', 'briefcase', 'house', 'heart', 'run', 'music', 'plane', 'dining', 'books', 'bulb', 'star'];

export const DEFAULT_TASK_ICON: ItemIconId = 'book';
export const FALLBACK_ICON: ItemIconId = 'circle';

/** 旧バージョンが保存した絵文字 → 新 ID（異体字セレクタ U+FE0F は除いて照合する） */
export const LEGACY_EMOJI_ICONS: Readonly<Record<string, ItemIconId>> = {
  '📘': 'book',
  '📗': 'book',
  '📙': 'book',
  '📕': 'book',
  '📖': 'book',
  '✏': 'pencil',
  '✍': 'pencil',
  '🖊': 'pencil',
  '💻': 'laptop',
  '🖥': 'laptop',
  '📝': 'note',
  '📄': 'note',
  '📚': 'books',
  '🧪': 'flask',
  '🔬': 'flask',
  '🎯': 'target',
  '💼': 'briefcase',
  '🏃': 'run',
  '🏋': 'run',
  '⚽': 'run',
  '🧹': 'sparkles',
  '✨': 'sparkles',
  '🛒': 'cart',
  '🍳': 'pan',
  '🎧': 'headphones',
  '💬': 'chat',
  '💡': 'bulb',
  '⭐': 'star',
  '🌟': 'star',
  '📅': 'calendar',
  '📆': 'calendar',
  '🗓': 'calendar',
  '🎓': 'graduation',
  '🏫': 'graduation',
  '🏠': 'house',
  '🏡': 'house',
  '❤': 'heart',
  '💖': 'heart',
  '🎵': 'music',
  '🎶': 'music',
  '✈': 'plane',
  '🍽': 'dining',
  '🍴': 'dining',
  '👤': 'person',
};

export interface ResolvedIcon {
  id: ItemIconId;
  /** 保存値が新しい ID そのもの */
  current: boolean;
  /** 旧形式（絵文字）を対応表で読み替えた */
  legacy: boolean;
}

export function isItemIconId(v: unknown): v is ItemIconId {
  return typeof v === 'string' && Object.prototype.hasOwnProperty.call(ITEM_ICONS, v);
}

/** 保存値を表示用のアイコン ID へ読み替える（保存値は変更しない） */
export function resolveItemIcon(value: string | null | undefined, fallback: ItemIconId = FALLBACK_ICON): ResolvedIcon {
  if (isItemIconId(value)) return { id: value, current: true, legacy: false };
  if (typeof value === 'string') {
    const key = value.replace(/️/g, '').trim();
    const mapped = Object.prototype.hasOwnProperty.call(LEGACY_EMOJI_ICONS, key) ? LEGACY_EMOJI_ICONS[key] : undefined;
    if (mapped) return { id: mapped, current: false, legacy: true };
  }
  return { id: fallback, current: false, legacy: false };
}

/** カレンダーの種類ごとの既定アイコン */
export function defaultCalendarIcon(kind: 'general' | 'class' | 'job' | string): ItemIconId {
  return kind === 'class' ? 'graduation' : kind === 'job' ? 'briefcase' : 'calendar';
}
