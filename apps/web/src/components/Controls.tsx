import type { ReactNode } from 'react';

/** iOS のスイッチ（オンは緑） */
export function Toggle({ checked, onChange, label, id }: { checked: boolean; onChange: (v: boolean) => void; label: string; id?: string }) {
  return (
    <button type="button" role="switch" id={id} aria-checked={checked} aria-label={label} className={`toggle ${checked ? 'on' : ''}`} onClick={() => onChange(!checked)}>
      <span className="toggle-knob" />
    </button>
  );
}

export function Segmented<T extends string>({ value, options, onChange, label }: { value: T; options: { value: T; label: string }[]; onChange: (v: T) => void; label: string }) {
  const idx = Math.max(0, options.findIndex((o) => o.value === value));
  return (
    <div className="segmented" role="radiogroup" aria-label={label} style={{ ['--n' as string]: options.length, ['--i' as string]: idx }}>
      <span className="segmented-thumb" aria-hidden />
      {options.map((o) => (
        <button key={o.value} type="button" role="radio" aria-checked={o.value === value} className={o.value === value ? 'active' : ''} onClick={() => onChange(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function Group({ header, footer, children }: { header?: ReactNode; footer?: ReactNode; children: ReactNode }) {
  return (
    <section className="group">
      {header && <div className="group-header">{header}</div>}
      <div className="group-body">{children}</div>
      {footer && <div className="group-footer">{footer}</div>}
    </section>
  );
}

export function Row({ label, children, onClick, destructive, accessory, htmlFor }: { label: ReactNode; children?: ReactNode; onClick?: () => void; destructive?: boolean; accessory?: ReactNode; htmlFor?: string }) {
  const inner = (
    <>
      {htmlFor ? (
        <label className="row-label" htmlFor={htmlFor}>
          {label}
        </label>
      ) : (
        <span className="row-label">{label}</span>
      )}
      <span className="row-value">{children}</span>
      {accessory}
    </>
  );
  return onClick ? (
    <button type="button" className={`row row-button ${destructive ? 'destructive' : ''}`} onClick={onClick}>
      {inner}
    </button>
  ) : (
    <div className="row">{inner}</div>
  );
}
