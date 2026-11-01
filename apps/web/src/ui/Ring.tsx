import { resolveItemIcon } from '@my-time/domain';
import { Icon } from '../components/Icon';

/** 進捗リング（中央にアイコン：Q36・Q86・Q94）。100% でチェックへ変わる */
export function Ring({ value, size = 40, icon, color = 'var(--blue)', done }: { value: number; size?: number; icon?: string; color?: string; done?: boolean }) {
  const stroke = Math.max(3, size / 12);
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const v = Math.max(0, Math.min(1, value));
  const complete = done ?? v >= 1;
  return (
    <span className="ring" style={{ width: size, height: size }} role="img" aria-label={`進捗 ${Math.round(v * 100)}%`}>
      <svg width={size} height={size} aria-hidden>
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="var(--ring-track)" strokeWidth={stroke} />
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={complete ? 'var(--green)' : color} strokeWidth={stroke} strokeLinecap="round" strokeDasharray={`${c * v} ${c}`} transform={`rotate(-90 ${size / 2} ${size / 2})`} style={{ transition: 'stroke-dasharray 400ms var(--spring)' }} />
      </svg>
      <span className="ring-inner" aria-hidden>{complete ? <Icon name="check" size={size * 0.42} strokeWidth={3} /> : icon ? <Icon name={resolveItemIcon(icon).id} size={size * 0.46} strokeWidth={2} /> : null}</span>
    </span>
  );
}
