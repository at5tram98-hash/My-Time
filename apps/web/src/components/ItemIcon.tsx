import { ITEM_ICONS, resolveItemIcon, type ItemIconId } from '@my-time/domain';
import type { CSSProperties } from 'react';
import { Icon } from './Icon';

/**
 * タスク・カレンダーに保存されたアイコン値を SVG で表示する。
 * 旧形式の絵文字は対応表で読み替え、未知の値は既定のアイコンにする（保存値は変更しない）。
 */
export function ItemIcon({ value, size = 20, strokeWidth, fallback, className, style }: { value: string | null | undefined; size?: number; strokeWidth?: number; fallback?: ItemIconId; className?: string; style?: CSSProperties }) {
  const r = resolveItemIcon(value, fallback);
  return (
    <span className={`item-icon ${className ?? ''}`} style={style} data-icon={r.id} data-icon-source={r.current ? 'id' : r.legacy ? 'legacy' : 'fallback'} aria-hidden>
      <Icon name={r.id} size={size} strokeWidth={strokeWidth ?? (size <= 16 ? 2.2 : 1.9)} />
    </span>
  );
}

/** アイコン選択（新しい SVG だけを並べ、選ぶと安定 ID を返す） */
export function IconPicker({ choices, value, onChange, label = 'アイコン' }: { choices: readonly ItemIconId[]; value: string | null | undefined; onChange: (id: ItemIconId) => void; label?: string }) {
  const selected = resolveItemIcon(value).id;
  return (
    <div className="icon-grid" role="radiogroup" aria-label={label}>
      {choices.map((id) => (
        <button key={id} type="button" role="radio" aria-checked={id === selected} aria-label={ITEM_ICONS[id]} className={`icon-choice ${id === selected ? 'on' : ''}`} onClick={() => onChange(id)} data-testid={`icon-${id}`}>
          <Icon name={id} size={22} strokeWidth={id === selected ? 2.1 : 1.8} />
        </button>
      ))}
    </div>
  );
}
