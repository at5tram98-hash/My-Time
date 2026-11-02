import { RingArc, TaskBadge, kindColor, type TaskKindTone } from '../components/Identity';

/**
 * 進捗リング（Q36・Q86・Q94・C05・C25・C28）。
 * アイコン付きはタスクの識別バッジ（円・種別色）として描き、外周に実績の円弧、中央に図形を置く。
 * 100%（完了）はチェック。value が null のときは未入力として円弧を描かない（0%にすり替えない）。
 */
export function Ring({ value, size = 40, icon, color, done, kind = 'do', ideal, delayed, running, label }: { value: number | null; size?: number; icon?: string; color?: string; done?: boolean; kind?: TaskKindTone; ideal?: number | null; delayed?: boolean; running?: boolean; label?: string }) {
  const v = value == null ? null : Math.max(0, Math.min(1, value));
  const complete = done ?? (v != null && v >= 1);
  const name = label ?? (v == null ? '進捗 未入力' : `進捗 ${Math.round(v * 100)}%`);
  if (icon !== undefined) {
    return <TaskBadge icon={icon} kind={kind} size={size} progress={v} ideal={ideal} done={complete} delayed={delayed} running={running} label={name} className="ring" />;
  }
  return (
    <span className="ring" style={{ width: size, height: size }} role="img" aria-label={name}>
      <RingArc value={complete ? 1 : v} size={size} color={color ?? kindColor(kind)} />
    </span>
  );
}
