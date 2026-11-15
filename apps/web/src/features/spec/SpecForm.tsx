import { checks, list, members, newId, num, slots, SPEC_BY_ID, steps, str, type SpecField, type SpecTypeId } from '@my-time/domain';
import { Icon } from '../../components/Icon';
import { Toggle } from '../../components/Controls';

const pad = (n: number) => String(n).padStart(2, '0');
const toLocal = (t: number | null, withTime: boolean) => { if (t == null) return ''; const d = new Date(t); const s = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`; return withTime ? `${s}T${pad(d.getHours())}:${pad(d.getMinutes())}` : s; };
const fromLocal = (v: string) => (v ? new Date(v).getTime() : null);

/**
 * 専門の種類の項目（編集画面の「種類」タブ）。項目は種類が決める。値は extra.spec.details に入る。
 * すべて任意。空のままでも保存でき、空の値から推定はしない。
 */
export function SpecForm({ type, values, onChange }: { type: SpecTypeId; values: Record<string, unknown>; onChange: (v: Record<string, unknown>) => void }) {
  const def = SPEC_BY_ID[type];
  const set = (k: string, v: unknown) => onChange({ ...values, [k]: v });
  return (
    <div data-testid="spec-form" data-spec={type}>
      <div className="group-header">{def.name}<span className="code-tag">{def.code}</span></div>
      <div className="group"><div className="group-body">
        {def.fields.map((f) => <Field key={f.key} f={f} v={values[f.key]} set={(x) => set(f.key, x)} />)}
      </div><div className="group-footer">{def.blurb}。すべて任意です。</div></div>
    </div>
  );
}

function Field({ f, v, set }: { f: SpecField; v: unknown; set: (v: unknown) => void }) {
  const label = <span className="ed-row-label">{f.label}{f.hint && <span className="sub-label wrap">{f.hint}</span>}</span>;
  const id = `spec-${f.key}`;
  switch (f.type) {
    case 'text': case 'url':
      return <label className="ed-row" htmlFor={id}>{label}<input id={id} className="row-input right" type={f.type === 'url' ? 'url' : 'text'} inputMode={f.type === 'url' ? 'url' : undefined} value={str(v)} placeholder={f.placeholder ?? '未入力'} onChange={(e) => set(e.target.value)} data-testid={`spec-field-${f.key}`} /></label>;
    case 'multiline':
      return <div className="ed-row ed-row-stack"><label htmlFor={id}>{label}</label><textarea id={id} className="row-input notes-input" rows={3} value={str(v)} onChange={(e) => set(e.target.value)} placeholder={f.placeholder ?? ''} /></div>;
    case 'number': case 'money': case 'minutes':
      return <label className="ed-row" htmlFor={id}>{label}<span className="dur-inputs"><input id={id} type="number" inputMode="numeric" min={0} value={num(v) ?? ''} onChange={(e) => set(e.target.value === '' ? null : Number(e.target.value))} data-testid={`spec-field-${f.key}`} />{f.unit}</span></label>;
    case 'date': case 'datetime':
      return <label className="ed-row" htmlFor={id}>{label}<input id={id} className="row-input right" type={f.type === 'date' ? 'date' : 'datetime-local'} value={toLocal(num(v), f.type === 'datetime')} onChange={(e) => set(fromLocal(e.target.value))} data-testid={`spec-field-${f.key}`} /></label>;
    case 'toggle':
      return <div className="ed-row">{label}<Toggle label={f.label} checked={v === true} onChange={set} /></div>;
    case 'select':
      return <label className="ed-row" htmlFor={id}>{label}<select id={id} className="select-input" value={str(v) || ''} onChange={(e) => set(e.target.value || null)}><option value="">未選択</option>{f.options!.map((o) => <option key={o} value={o}>{o}</option>)}</select></label>;
    case 'list':
      return <div className="ed-row ed-row-stack"><label htmlFor={id}>{label}</label><textarea id={id} className="row-input notes-input" rows={2} value={list(v).join('\n')} onChange={(e) => set(e.target.value.split('\n').map((x) => x.trim()).filter(Boolean))} placeholder={f.placeholder ?? '1行に1つ'} /></div>;
    case 'checklist': {
      const items = checks(v);
      return (
        <div className="ed-row ed-row-stack" data-testid={`spec-field-${f.key}`}>
          {label}
          {items.map((x, i) => (
            <div key={x.id} className="spec-edit-line">
              <input type="checkbox" checked={x.done} onChange={(e) => set(items.map((y, j) => (j === i ? { ...y, done: e.target.checked } : y)))} aria-label={`${x.name || '項目'}を完了`} />
              <input className="row-input" value={x.name} onChange={(e) => set(items.map((y, j) => (j === i ? { ...y, name: e.target.value } : y)))} aria-label="項目名" />
              <button type="button" className="link-del" aria-label={`${x.name || '項目'}を外す`} onClick={() => set(items.filter((_, j) => j !== i))}><Icon name="close" size={13} strokeWidth={2.6} /></button>
            </div>
          ))}
          <button type="button" className="link-btn small" onClick={() => set([...items, { id: newId(), name: '', done: false }])} data-testid={`spec-add-${f.key}`}>＋ 追加</button>
        </div>
      );
    }
    case 'steps': {
      const items = steps(v);
      return (
        <div className="ed-row ed-row-stack">
          {label}
          {items.map((x, i) => (
            <div key={i} className="spec-edit-line">
              <input className="row-input" value={x.title} onChange={(e) => set(items.map((y, j) => (j === i ? { ...y, title: e.target.value } : y)))} aria-label="工程名" />
              <span className="dur-inputs"><input type="number" min={0} value={x.minutes} onChange={(e) => set(items.map((y, j) => (j === i ? { ...y, minutes: Number(e.target.value) || 0 } : y)))} aria-label="分" />分</span>
              <button type="button" className="link-del" aria-label={`${x.title || '工程'}を外す`} onClick={() => set(items.filter((_, j) => j !== i))}><Icon name="close" size={13} strokeWidth={2.6} /></button>
            </div>
          ))}
          <button type="button" className="link-btn small" onClick={() => set([...items, { title: '', minutes: 10 }])}>＋ 工程を追加</button>
        </div>
      );
    }
    case 'members': {
      const ms = members(v);
      return (
        <div className="ed-row ed-row-stack">
          {label}
          {ms.map((m, i) => (
            <div key={i} className="spec-edit-line wrap">
              <input className="row-input" value={m.name} placeholder="名前" onChange={(e) => set(ms.map((y, j) => (j === i ? { ...y, name: e.target.value } : y)))} aria-label="名前" />
              <input className="row-input" value={m.part} placeholder="担当" onChange={(e) => set(ms.map((y, j) => (j === i ? { ...y, part: e.target.value } : y)))} aria-label="担当" />
              <label className="small"><input type="checkbox" checked={m.mine} onChange={(e) => set(ms.map((y, j) => (j === i ? { ...y, mine: e.target.checked } : y)))} />自分</label>
              <select className="select-input" value={m.status} onChange={(e) => set(ms.map((y, j) => (j === i ? { ...y, status: e.target.value } : y)))} aria-label="状態"><option value="todo">未着手</option><option value="waiting">待っている</option><option value="done">完了</option></select>
              <button type="button" className="link-del" aria-label="外す" onClick={() => set(ms.filter((_, j) => j !== i))}><Icon name="close" size={13} strokeWidth={2.6} /></button>
            </div>
          ))}
          <button type="button" className="link-btn small" onClick={() => set([...ms, { name: '', part: '', mine: ms.length === 0, status: 'todo' }])}>＋ 分担を追加</button>
        </div>
      );
    }
    case 'slots': {
      const ss = slots(v);
      return (
        <div className="ed-row ed-row-stack">
          {label}
          {ss.map((x, i) => (
            <div key={i} className="spec-edit-line wrap">
              <input type="datetime-local" value={toLocal(x.start, true)} onChange={(e) => { const s = fromLocal(e.target.value); if (s != null) set(ss.map((y, j) => (j === i ? { start: s, end: Math.max(s + 15 * 60_000, y.end) } : y))); }} aria-label="開始" />
              <input type="datetime-local" value={toLocal(x.end, true)} onChange={(e) => { const t = fromLocal(e.target.value); if (t != null && t > x.start) set(ss.map((y, j) => (j === i ? { ...y, end: t } : y))); }} aria-label="終了" />
              <button type="button" className="link-del" aria-label="外す" onClick={() => set(ss.filter((_, j) => j !== i))}><Icon name="close" size={13} strokeWidth={2.6} /></button>
            </div>
          ))}
          <button type="button" className="link-btn small" onClick={() => { const s = new Date(); s.setDate(s.getDate() + 1); s.setHours(18, 0, 0, 0); set([...ss, { start: s.getTime(), end: s.getTime() + 4 * 3_600_000 }]); }}>＋ 枠を追加</button>
        </div>
      );
    }
  }
}
