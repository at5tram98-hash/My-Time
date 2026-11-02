import { motion, useReducedMotion } from 'motion/react';
import { Icon, type IconName } from '../components/Icon';
import { SPRING } from './motion';

export interface KindOption<T extends string> { value: T; label: string; tone: 'do' | 'check' | 'neutral'; icon?: IconName; count?: number; testId?: string }

/**
 * 実行（赤）／確認（青）／すべて（中立）の独立した押しボタン（C10・C30）。
 * つながったセグメントではなく、それぞれが独立したボタン。選択中だけが最も大きく、強い面になる。
 * 高さは選択時の大きさで予約し、拡大で下の一覧が跳ねない。Reduced Motion では拡大せず色・枠・チェックで示す。
 */
export function KindButtons<T extends string>({ options, value, onChange, label, size = 'm' }: { options: KindOption<T>[]; value: T; onChange: (v: T) => void; label: string; size?: 's' | 'm' }) {
  const reduce = useReducedMotion();
  const onKey = (e: React.KeyboardEvent, i: number) => {
    if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
    e.preventDefault();
    const n = options[(i + (e.key === 'ArrowRight' ? 1 : options.length - 1)) % options.length]!;
    onChange(n.value);
    (e.currentTarget.parentElement?.querySelectorAll('button')[options.indexOf(n)] as HTMLButtonElement | undefined)?.focus();
  };
  return (
    <div className={`kind-buttons ${size}`} role="group" aria-label={label}>
      {options.map((o, i) => {
        const on = o.value === value;
        return (
          <motion.button
            key={o.value}
            type="button"
            className={`kind-btn tone-${o.tone} ${on ? 'on' : ''}`}
            aria-pressed={on}
            onClick={() => onChange(o.value)}
            onKeyDown={(e) => onKey(e, i)}
            data-testid={o.testId}
            animate={reduce ? { scale: 1 } : { scale: on ? 1.06 : 1 }}
            whileTap={reduce ? undefined : { scale: on ? 1.0 : 0.94 }}
            transition={SPRING.pop}
          >
            {on ? <Icon name="check" size={size === 's' ? 13 : 15} strokeWidth={2.8} /> : o.icon ? <Icon name={o.icon} size={size === 's' ? 13 : 15} strokeWidth={2.4} /> : null}
            <span className="kind-btn-label">{o.label}</span>
            {o.count != null && <span className="kind-btn-count">{o.count}</span>}
          </motion.button>
        );
      })}
    </div>
  );
}
