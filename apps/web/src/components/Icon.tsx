import type { CSSProperties } from 'react';

/** SF Symbols を複製せず、同じ考え方の線アイコンを独自に描いたもの */
const PATHS = {
  house: 'M4 11.5 12 4.5l8 7M6.5 9.5V19a1 1 0 0 0 1 1H10v-5h4v5h2.5a1 1 0 0 0 1-1V9.5',
  calendar: 'M5 6.5h14a1 1 0 0 1 1 1V19a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7.5a1 1 0 0 1 1-1ZM4 10.5h16M8.5 4v4M15.5 4v4',
  checklist: 'M10 7h10M10 12h10M10 17h10M4 7l1.3 1.3L7.6 6M4 12l1.3 1.3L7.6 11M4.8 17h.01',
  chart: 'M5 20V12M10 20V5M15 20v-9M20 20v-5',
  more: 'M6 12h.01M12 12h.01M18 12h.01',
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
} as const;

export type IconName = keyof typeof PATHS | 'days1' | 'days2' | 'daysN';

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
