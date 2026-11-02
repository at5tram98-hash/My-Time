import { useState } from 'react';
import { formatValue, studioProgress, unitLabel, type StudioField, type StudioType } from '@my-time/domain';
import { Toggle } from '../../components/Controls';
import { Icon } from '../../components/Icon';
import { Ring } from '../../ui/Ring';

/** 部品の型に合う入力部品（Q70・Q85・Q104）。値は項目IDに結びつける */
export function StudioFieldInput({ f, value, onChange }: { f: StudioField; value: unknown; onChange: (v: unknown) => void }) {
  const [unitHour, setUnitHour] = useState(false);
  switch (f.type) {
    case 'text':
      return <input className="row-input right" value={(value as string) ?? ''} onChange={(e) => onChange(e.target.value)} placeholder="未入力" aria-label={f.label} />;
    case 'multiline':
      return <textarea className="row-input notes-input" value={(value as string) ?? ''} onChange={(e) => onChange(e.target.value)} placeholder={f.label} aria-label={f.label} rows={3} />;
    case 'number':
    case 'progress':
      return (
        <span className="dur-inputs">
          <label>
            <input type="number" inputMode="decimal" step={f.precision ? 1 / 10 ** f.precision : 1} min={f.min ?? undefined} max={f.type === 'progress' ? 100 : f.max ?? undefined} value={value == null ? '' : String(value)} onChange={(e) => onChange(e.target.value === '' ? null : Number(e.target.value))} aria-label={f.label} data-testid={`studio-field-${f.id}`} />
            {f.type === 'progress' ? '%' : unitLabel(f.unit)}
          </label>
          <button type="button" className="stepper-btn" aria-label={`${f.label}を1増やす`} onClick={() => onChange(Math.min(f.type === 'progress' ? 100 : f.max ?? Infinity, Number(value ?? 0) + 1))}><Icon name="plus" size={14} /></button>
        </span>
      );
    case 'duration': {
      const m = Number(value ?? 0);
      return (
        <span className="dur-inputs">
          <label><input type="number" inputMode="decimal" value={value == null ? '' : unitHour ? +(m / 60).toFixed(2) : m} onChange={(e) => onChange(e.target.value === '' ? null : Math.round(Number(e.target.value) * (unitHour ? 60 : 1)))} aria-label={f.label} />{unitHour ? '時間' : '分'}</label>
          <button type="button" className="stepper-btn" onClick={() => setUnitHour((h) => !h)} aria-label="単位を切り替える">{unitHour ? '分で' : '時間で'}</button>
        </span>
      );
    }
    case 'datetime':
      return <input type="datetime-local" className="dt-input" value={typeof value === 'number' ? new Date(value - new Date(value).getTimezoneOffset() * 60_000).toISOString().slice(0, 16) : ''} onChange={(e) => onChange(e.target.value ? new Date(e.target.value).getTime() : null)} aria-label={f.label} />;
    case 'toggle':
    case 'check':
      return <Toggle label={f.label} checked={value === true} onChange={(b) => onChange(b)} />;
    case 'select':
      return (
        <select className="select-input" value={(value as string) ?? ''} onChange={(e) => onChange(e.target.value || null)} aria-label={f.label}>
          <option value="">未選択</option>
          {(f.options ?? []).map((o) => <option key={o} value={o}>{o}</option>)}
        </select>
      );
    case 'multiselect': {
      const arr = Array.isArray(value) ? (value as string[]) : [];
      return (
        <span className="chips">
          {(f.options ?? []).map((o) => <button key={o} type="button" className={`chip-opt ${arr.includes(o) ? 'on' : ''}`} aria-pressed={arr.includes(o)} onClick={() => onChange(arr.includes(o) ? arr.filter((x) => x !== o) : [...arr, o])}>{o}</button>)}
        </span>
      );
    }
    case 'url':
      return <input className="row-input right" type="url" inputMode="url" value={(value as string) ?? ''} onChange={(e) => onChange(e.target.value)} placeholder="https://" aria-label={f.label} />;
    case 'place':
      return <input className="row-input right" value={(value as { name?: string } | null)?.name ?? ''} onChange={(e) => onChange(e.target.value ? { name: e.target.value, address: '', lat: null, lng: null } : null)} placeholder="場所の名前" aria-label={f.label} />;
    case 'file':
      return <span className="muted small">「オプション」の添付ファイルに追加</span>;
    case 'worktime':
      return <span className="muted small">開始〜完了の記録から自動</span>;
    case 'note':
      return null;
  }
}

/** 編集画面「専用」タブ：Studio の種類の項目をセクションごとに表示（Q70） */
export function StudioFieldsForm({ type, values, onChange }: { type: StudioType; values: Record<string, unknown>; onChange: (v: Record<string, unknown>) => void }) {
  const pr = studioProgress(type, values);
  return (
    <div data-testid="studio-fields">
      {pr.value != null && (
        <div className="studio-progress"><Ring value={pr.value} size={44} icon={type.icon} /><span>{pr.label}{pr.over ? '（目標を超えました）' : ''}</span></div>
      )}
      {type.sections.map((s) => {
        const fields = type.fields.filter((f) => f.sectionId === s.id && !f.hidden);
        if (!fields.length) return null;
        return (
          <div key={s.id}>
            <div className="group-header">{s.title}</div>
            <div className="group"><div className="group-body">
              {fields.map((f) =>
                f.type === 'note' ? (
                  <p key={f.id} className="note-text studio-note">{f.body || f.label}</p>
                ) : f.type === 'multiline' ? (
                  <div key={f.id} className="studio-ml"><span className="ed-row-label">{f.label}{f.required ? '（必須）' : ''}</span><StudioFieldInput f={f} value={values[f.id]} onChange={(x) => onChange({ ...values, [f.id]: x })} /></div>
                ) : (
                  <div key={f.id} className="ed-row">
                    <span className="ed-row-label">{f.label}{f.required ? <span className="req">必須</span> : null}</span>
                    <span className="ed-row-value"><StudioFieldInput f={f} value={values[f.id]} onChange={(x) => onChange({ ...values, [f.id]: x })} /></span>
                  </div>
                ),
              )}
            </div></div>
          </div>
        );
      })}
    </div>
  );
}

/** 情報確認シートなどでの表示（型に合う見せ方：Q87・Q104） */
export function StudioValueView({ f, value }: { f: StudioField; value: unknown }) {
  if (value == null || value === '' || (Array.isArray(value) && !value.length)) return null;
  switch (f.type) {
    case 'number': return <>{formatValue(f, Number(value))}</>;
    case 'progress': return <>{Math.round(Number(value))}%</>;
    case 'duration': { const m = Number(value); return <>{m >= 60 ? `${Math.floor(m / 60)}時間${m % 60 ? `${m % 60}分` : ''}` : `${m}分`}</>; }
    case 'datetime': { const d = new Date(Number(value)); return <>{`${d.getMonth() + 1}/${d.getDate()} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`}</>; }
    case 'toggle': case 'check': return value === true ? <Icon name="check" size={16} strokeWidth={2.6} className="tint" label="はい" /> : <span className="muted">いいえ</span>;
    case 'multiselect': return <>{(value as string[]).join('・')}</>;
    case 'url': return <a href={String(value)} target="_blank" rel="noreferrer noopener" className="tint">開く</a>;
    case 'place': return <>{(value as { name: string }).name}</>;
    default: return <>{String(value)}</>;
  }
}
