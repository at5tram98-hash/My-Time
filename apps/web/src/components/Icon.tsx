import type { CSSProperties } from 'react';
import type { ItemIconId } from '@my-time/domain';

/**
 * アプリの全アイコン（独自に描いた線アイコン。SF Symbols 等の素材は複製・同梱していない）。
 * 24 グリッド・丸端・丸角。線幅は既定 1.9（16px 以下では呼び出し側で 2.2〜3 に太くする）。
 * 絵文字・記号の文字をアイコン代わりに使わず、必ずここを通す。
 */
const PATHS = {
  house: 'M4 11.5 12 4.5l8 7M6.5 9.5V19a1 1 0 0 0 1 1H10v-5h4v5h2.5a1 1 0 0 0 1-1V9.5',
  calendar: 'M5 6.5h14a1 1 0 0 1 1 1V19a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7.5a1 1 0 0 1 1-1ZM4 10.5h16M8.5 4v4M15.5 4v4',
  checklist: 'M10 7h10M10 12h10M10 17h10M4 7l1.3 1.3L7.6 6M4 12l1.3 1.3L7.6 11M4.8 17h.01',
  chart: 'M5 20V12M10 20V5M15 20v-9M20 20v-5',
  more: 'M6 12h.01M12 12h.01M18 12h.01',
  moreCircle: 'M12 20.5a8.5 8.5 0 1 0 0-17 8.5 8.5 0 0 0 0 17ZM8 12.9a.9.9 0 1 0 0-1.8.9.9 0 0 0 0 1.8ZM12 12.9a.9.9 0 1 0 0-1.8.9.9 0 0 0 0 1.8ZM16 12.9a.9.9 0 1 0 0-1.8.9.9 0 0 0 0 1.8Z',
  search: 'M10.5 17a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13ZM15.3 15.3 20 20',
  plus: 'M12 5v14M5 12h14',
  close: 'M6 6l12 12M18 6 6 18',
  chevronRight: 'm9 5 7 7-7 7',
  chevronLeft: 'm15 5-7 7 7 7',
  chevronDown: 'm6 9 6 6 6-6',
  play: 'M8 5.5v13l10.5-6.5L8 5.5Z',
  pause: 'M8.5 5.5v13M15.5 5.5v13',
  check: 'm5 12.5 4.5 4.5L19 7.5',
  undo: 'M9 14 4.5 9.5 9 5M4.5 9.5H14a5.5 5.5 0 0 1 0 11h-3',
  trash: 'M4.5 7h15M9.5 7V4.5h5V7M6.5 7l1 13h9l1-13M10 11v5.5M14 11v5.5',
  pencil: 'M15 5.5 18.5 9M4.5 19.5l1-4.5L16 4.5a1.4 1.4 0 0 1 2 0l1.5 1.5a1.4 1.4 0 0 1 0 2L9 18.5l-4.5 1Z',
  copy: 'M9 9h10v11H9zM15 9V4H5v11h4',
  clock: 'M12 20.5a8.5 8.5 0 1 0 0-17 8.5 8.5 0 0 0 0 17ZM12 7.5V12l3 2',
  expand: 'M12 3.5v6M9 6.5l3-3 3 3M12 20.5v-6M9 17.5l3 3 3-3M4 12h16',
  today: 'M5 6.5h14a1 1 0 0 1 1 1V19a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7.5a1 1 0 0 1 1-1ZM4 10.5h16M12 13.5v3.5',
  flag: 'M6 20V4.5M6 5h11l-2.5 4L17 13H6',
  cloud: 'M7 18.5h10.5a4 4 0 0 0 .5-8 6 6 0 0 0-11.6 1.6A3.3 3.3 0 0 0 7 18.5Z',
  bell: 'M6 16.5V11a6 6 0 1 1 12 0v5.5l1.5 2h-15l1.5-2ZM10 20.5h4',
  textsize: 'M4 18 8.5 6 13 18M5.6 14h5.8M14.5 18l3-8 3 8M15.5 15.5h4',
  paint: 'M12 20.5a8.5 8.5 0 1 1 8.5-8.5c0 2-1.5 3-3.5 3h-2a2 2 0 0 0-1.5 3.3c.6.8.2 2.2-1.5 2.2ZM7.5 12h.01M9.5 8h.01M14.5 8h.01',
  person: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM4.5 20a7.5 7.5 0 0 1 15 0',
  info: 'M12 20.5a8.5 8.5 0 1 0 0-17 8.5 8.5 0 0 0 0 17ZM12 11v5.5M12 7.8h.01',
  tray: 'M4 13.5 6.5 5h11l2.5 8.5V19H4v-5.5ZM4 13.5h4.5l1 2h5l1-2H20',
  stack: 'M12 4 20 8l-8 4-8-4 8-4ZM4 12l8 4 8-4M4 16l8 4 8-4',
  arrowUpDown: 'M8 4v16M4.5 7.5 8 4l3.5 3.5M16 20V4M12.5 16.5 16 20l3.5-3.5',
  link: 'M10 14a4 4 0 0 0 5.7 0l3-3A4 4 0 0 0 13 5.3l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1',
  // ---- ユーザーが選ぶアイコン（ID は packages/domain/src/icons.ts）----
  book: 'M12 6.5C10 5 7 4.5 4 5v13c3-.5 6 0 8 1.5 2-1.5 5-2 8-1.5V5c-3-.5-6 0-8 1.5ZM12 6.5v13',
  laptop: 'M5.5 15V7a1 1 0 0 1 1-1h11a1 1 0 0 1 1 1v8M3.5 15h17l-1 3.5h-15l-1-3.5Z',
  note: 'M7 3.5h7.5L19 8v11.5a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1v-15a1 1 0 0 1 1-1ZM14.5 3.5V8H19M9 12.5h7M9 16h5',
  books: 'M4.5 4.5h4v15h-4zM8.5 4.5h4v15h-4zM13.6 5.6l3.8-1 3.9 14.4-3.8 1-3.9-14.4Z',
  flask: 'M9.5 3.5h5M10.5 3.5V9L5 18.5a1.3 1.3 0 0 0 1.1 2h11.8a1.3 1.3 0 0 0 1.1-2L13.5 9V3.5M7.4 14.5h9.2',
  target: 'M12 20.5a8.5 8.5 0 1 0 0-17 8.5 8.5 0 0 0 0 17ZM12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM12 12h.01',
  briefcase: 'M4.5 8h15a1 1 0 0 1 1 1v9.5a1 1 0 0 1-1 1h-15a1 1 0 0 1-1-1V9a1 1 0 0 1 1-1ZM9 8V5.5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1V8M3.5 13h17',
  run: 'M15 6.5a1.75 1.75 0 1 0 0-3.5 1.75 1.75 0 0 0 0 3.5ZM7 11l3.5-3 3.5.8 2 3.2h3M11 9.5 9.5 15l4 2.5-1 4M9.5 15 7 18.5H4',
  sparkles: 'M10.5 4l1.7 4.6 4.6 1.7-4.6 1.7-1.7 4.6-1.7-4.6-4.6-1.7 4.6-1.7L10.5 4ZM18 14.5l.8 2 2 .8-2 .8-.8 2-.8-2-2-.8 2-.8.8-2Z',
  cart: 'M3.5 4.5h2.2l2 10.5h10.1l2-7.5H6.6M9 20a1 1 0 1 0 0-2 1 1 0 0 0 0 2ZM17 20a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z',
  pan: 'M3.5 11h13v1.5a5 5 0 0 1-5 5h-3a5 5 0 0 1-5-5V11ZM16.5 12.5h4M8 7.5c0-1 1-1.5 1-2.5M12 7.5c0-1 1-1.5 1-2.5',
  headphones: 'M4.5 16v-3.5a7.5 7.5 0 0 1 15 0V16M4.5 14.5H7a1 1 0 0 1 1 1V19a1 1 0 0 1-1 1H5.5a1 1 0 0 1-1-1v-4.5ZM19.5 14.5H17a1 1 0 0 0-1 1V19a1 1 0 0 0 1 1h1.5a1 1 0 0 0 1-1v-4.5Z',
  chat: 'M5 5h14a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1h-8l-4.5 3.5V16H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1Z',
  bulb: 'M9.5 17.5h5M10.2 20.5h3.6M12 3.5a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2v1.1h5v-1.1c0-.8.4-1.5 1-2A6 6 0 0 0 12 3.5Z',
  star: 'M12 3.8l2.5 5.2 5.7.8-4.1 4 1 5.6L12 16.7l-5.1 2.7 1-5.6-4.1-4 5.7-.8L12 3.8Z',
  graduation: 'M2.5 9.5 12 5l9.5 4.5L12 14 2.5 9.5ZM6.5 11.5V16c0 1.4 2.5 3 5.5 3s5.5-1.6 5.5-3v-4.5M21.5 9.5V15',
  heart: 'M12 19.5s-7.5-4.6-7.5-10A4 4 0 0 1 12 7.2a4 4 0 0 1 7.5 2.3c0 5.4-7.5 10-7.5 10Z',
  music: 'M9 17.5V5.5l10-2v12M9 9.5l10-2M9 17.5a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0ZM19 15.5a2.5 2.5 0 1 1-5 0 2.5 2.5 0 0 1 5 0Z',
  plane: 'M12 3c.8 0 1.5.7 1.5 1.5V9l7 4v2l-7-2v4.5l2 1.5v1.5L12 19.6l-3.5.9V19l2-1.5V13l-7 2v-2l7-4V4.5C10.5 3.7 11.2 3 12 3Z',
  dining: 'M7 3.5v17M4.5 3.5V8a2.5 2.5 0 0 0 5 0V3.5M17 20.5v-17c-2 1-3.5 3.5-3.5 7v2H17',
  circle: 'M12 19a7 7 0 1 0 0-14 7 7 0 0 0 0 14Z',
  // ---- 状態・案内 ----
  people: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7ZM2.5 20a6.5 6.5 0 0 1 13 0M15.5 4.3a3.5 3.5 0 0 1 0 6.4M18 13.8a6.5 6.5 0 0 1 3.5 6.2',
  warning: 'M10.7 4.6a1.5 1.5 0 0 1 2.6 0l7.6 13.2a1.5 1.5 0 0 1-1.3 2.2H4.4a1.5 1.5 0 0 1-1.3-2.2l7.6-13.2ZM12 9.5v4.5M12 17h.01',
  exclamation: 'M12 5.5v8.5M12 18.5h.01',
  stopwatch: 'M12 21a7.5 7.5 0 1 0 0-15 7.5 7.5 0 0 0 0 15ZM12 9.5v4l2.5 1.5M9.5 2.5h5M12 2.5V6M18.5 6.5l1.2-1.2',
} as const;

export type IconName = keyof typeof PATHS | 'days1' | 'days2' | 'daysN';

/** ユーザーが選べるアイコン ID はすべて描画できること（型で保証） */
const ITEM_ICON_PATHS: Record<ItemIconId, string> = PATHS;
export const hasItemIcon = (id: ItemIconId): boolean => Boolean(ITEM_ICON_PATHS[id]);

interface Props {
  name: IconName;
  size?: number;
  strokeWidth?: number;
  className?: string;
  style?: CSSProperties;
  label?: string;
}

export function Icon({ name, size = 24, strokeWidth = 1.9, className, style, label }: Props) {
  const common = {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    className,
    style,
    'aria-hidden': label ? undefined : true,
    'aria-label': label,
    role: label ? 'img' : undefined,
  };
  if (name === 'days1' || name === 'days2' || name === 'daysN') {
    // 1日 / 2日 / 複数日 を形だけで示す（文字のセグメント切替を使わない）
    return (
      <svg {...common}>
        <rect x="4" y="4.5" width="16" height="15" rx="2.5" />
        {name === 'days2' && <path d="M12 4.5v15" />}
        {name === 'daysN' && <path d="M9.3 4.5v15M14.7 4.5v15" />}
        {name === 'days1' && <path d="M8 9h8M8 12.5h8M8 16h5" />}
      </svg>
    );
  }
  return (
    <svg {...common}>
      <path d={PATHS[name]} />
    </svg>
  );
}
