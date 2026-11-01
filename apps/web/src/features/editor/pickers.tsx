import { useEffect, useMemo, useRef, useState } from 'react';
import { addDays, CALENDAR_ICON_CHOICES, ITEM_ICONS, resolveItemIcon, startOfDay, TASK_ICON_CHOICES, weekday, type ItemIconId, type PlaceValue, type RecurrenceRule } from '@my-time/domain';
import { Icon } from '../../components/Icon';
import { Popup } from '../../ui/Popup';

const WD = ['日', '月', '火', '水', '木', '金', '土'];
const pad = (n: number) => String(n).padStart(2, '0');

// ---------------- 日付ピッカー（Q73） ----------------
/** 月カレンダー。左右スワイプ・矢印で月移動、年月タップで素早く選ぶ。今日・選択中・範囲外を区別 */
export function DatePickerPopup({ open, value, min, onClose, onPick, title = '日付' }: { open: boolean; value: number; min?: number | null; onClose: () => void; onPick: (day: number) => void; title?: string }) {
  const [month, setMonth] = useState(() => { const d = new Date(value); return new Date(d.getFullYear(), d.getMonth(), 1).getTime(); });
  const [sel, setSel] = useState(startOfDay(value));
  const [ym, setYm] = useState(false);
  useEffect(() => { if (open) { const d = new Date(value); setMonth(new Date(d.getFullYear(), d.getMonth(), 1).getTime()); setSel(startOfDay(value)); setYm(false); } }, [open, value]);
  const m = new Date(month);
  const first = startOfDay(month);
  const gridStart = addDays(first, -weekday(first));
  const cells = Array.from({ length: 42 }, (_, i) => addDays(gridStart, i));
  const today = startOfDay(Date.now());
  const step = (dir: number) => setMonth(new Date(m.getFullYear(), m.getMonth() + dir, 1).getTime());
  const sx = useRef<number | null>(null);
  return (
    <Popup open={open} title={title} onClose={onClose} onDone={() => onPick(sel)} testId="date-picker">
      <div className="dp-head">
        <button type="button" className="dp-ym" onClick={() => setYm((v) => !v)} aria-expanded={ym} data-testid="dp-ym">{m.getFullYear()}年{m.getMonth() + 1}月 <Icon name="chevronDown" size={14} strokeWidth={2.4} /></button>
        <span className="dp-nav">
          <button type="button" className="gbtn glass glass-i" aria-label="前の月" onClick={() => step(-1)}><Icon name="chevronLeft" size={18} /></button>
          <button type="button" className="gpill glass glass-i" onClick={() => { setMonth(new Date(new Date(today).getFullYear(), new Date(today).getMonth(), 1).getTime()); setSel(today); }}>今日</button>
          <button type="button" className="gbtn glass glass-i" aria-label="次の月" onClick={() => step(1)}><Icon name="chevronRight" size={18} /></button>
        </span>
      </div>
      {ym ? (
        <div className="dp-ymgrid" role="group" aria-label="年と月">
          <div className="dp-years">
            {Array.from({ length: 9 }, (_, i) => m.getFullYear() - 4 + i).map((y) => (
              <button key={y} type="button" aria-pressed={y === m.getFullYear()} onClick={() => setMonth(new Date(y, m.getMonth(), 1).getTime())}>{y}</button>
            ))}
          </div>
          <div className="dp-months">
            {Array.from({ length: 12 }, (_, i) => i).map((i) => (
              <button key={i} type="button" aria-pressed={i === m.getMonth()} onClick={() => { setMonth(new Date(m.getFullYear(), i, 1).getTime()); setYm(false); }}>{i + 1}月</button>
            ))}
          </div>
        </div>
      ) : (
        <div className="dp-grid" role="grid" aria-label={`${m.getFullYear()}年${m.getMonth() + 1}月`}
          onPointerDown={(e) => (sx.current = e.clientX)}
          onPointerUp={(e) => { if (sx.current != null && Math.abs(e.clientX - sx.current) > 50) step(e.clientX < sx.current ? 1 : -1); sx.current = null; }}>
          {WD.map((w) => <span key={w} className="dp-wd" aria-hidden>{w}</span>)}
          {cells.map((d) => {
            const out = new Date(d).getMonth() !== m.getMonth();
            const disabled = min != null && d < startOfDay(min);
            return (
              <button key={d} type="button" role="gridcell" disabled={disabled} aria-selected={d === sel} aria-current={d === today ? 'date' : undefined}
                className={`dp-day ${out ? 'out' : ''} ${d === sel ? 'sel' : ''} ${d === today ? 'today' : ''}`} onClick={() => setSel(d)} data-testid={out ? undefined : `dp-day-${new Date(d).getDate()}`}>
                {new Date(d).getDate()}
              </button>
            );
          })}
        </div>
      )}
    </Popup>
  );
}

// ---------------- 時刻ホイール（Q74） ----------------
function Wheel({ values, value, onChange, label, format }: { values: number[]; value: number; onChange: (v: number) => void; label: string; format: (v: number) => string }) {
  const ref = useRef<HTMLDivElement>(null);
  const ROW = 40;
  const idx = Math.max(0, values.indexOf(value));
  useEffect(() => { const el = ref.current; if (el) el.scrollTop = idx * ROW; }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const t = useRef(0);
  return (
    <div className="wheel" role="listbox" aria-label={label} ref={ref}
      onScroll={(e) => {
        const el = e.currentTarget;
        window.clearTimeout(t.current);
        t.current = window.setTimeout(() => { const i = Math.min(values.length - 1, Math.max(0, Math.round(el.scrollTop / ROW))); if (values[i] !== value) onChange(values[i]!); }, 80);
      }}>
      <div className="wheel-pad" />
      {values.map((v, i) => (
        <button key={v} type="button" role="option" aria-selected={i === idx} className={`wheel-item ${i === idx ? 'on' : ''}`} onClick={() => { ref.current?.scrollTo({ top: i * ROW, behavior: 'smooth' }); onChange(v); }}>{format(v)}</button>
      ))}
      <div className="wheel-pad" />
    </div>
  );
}

/** 24時間表示。通常5分刻み、切替で1分刻み。選択中は未確定、「完了」で確定 */
export function TimeWheelPopup({ open, value, onClose, onPick, title = '時刻' }: { open: boolean; value: number; onClose: () => void; onPick: (t: number) => void; title?: string }) {
  const d0 = new Date(value);
  const [h, setH] = useState(d0.getHours());
  const [mi, setMi] = useState(d0.getMinutes());
  const [fine, setFine] = useState(d0.getMinutes() % 5 !== 0);
  useEffect(() => { if (open) { const d = new Date(value); setH(d.getHours()); setMi(d.getMinutes()); setFine(d.getMinutes() % 5 !== 0); } }, [open, value]);
  const mins = fine ? Array.from({ length: 60 }, (_, i) => i) : Array.from({ length: 12 }, (_, i) => i * 5);
  const shownMin = fine ? mi : Math.round(mi / 5) * 5 % 60;
  return (
    <Popup open={open} title={title} onClose={onClose} onDone={() => { const d = new Date(value); d.setHours(h, shownMin, 0, 0); onPick(d.getTime()); }} testId="time-wheel">
      <div className="wheel-wrap" key={`${open}-${fine}`}>
        <div className="wheel-band" aria-hidden />
        <Wheel values={Array.from({ length: 24 }, (_, i) => i)} value={h} onChange={setH} label="時" format={(v) => pad(v)} />
        <span className="wheel-colon" aria-hidden>:</span>
        <Wheel values={mins} value={shownMin} onChange={setMi} label="分" format={(v) => pad(v)} />
      </div>
      <div className="wheel-opts">
        <button type="button" className="gpill glass glass-i" aria-pressed={fine} onClick={() => setFine((f) => !f)}>{fine ? '5分刻みにする' : '1分刻みにする'}</button>
        <span className="muted small" data-testid="time-wheel-value">{pad(h)}:{pad(shownMin)}</span>
      </div>
    </Popup>
  );
}

// ---------------- 繰り返し（Q67・Q75） ----------------
export function describeRule(r: RecurrenceRule | null): string {
  if (!r) return 'しない';
  if (r.freq === 'weekly' && r.interval === 1 && r.byWeekday && r.byWeekday.length === 5 && [1, 2, 3, 4, 5].every((d) => r.byWeekday!.includes(d))) return `平日${r.until ? '（期限あり）' : ''}`;
  const every = r.interval > 1 ? `${r.interval}${r.freq === 'daily' ? '日' : r.freq === 'weekly' ? '週' : 'か月'}ごと` : { daily: '毎日', weekly: '毎週', monthly: '毎月' }[r.freq];
  const days = r.freq === 'weekly' && r.byWeekday?.length ? `（${[...r.byWeekday].sort().map((d) => WD[d]).join('・')}）` : '';
  return `${every}${days}${r.until ? '・期限あり' : ''}`;
}

export function RecurrencePopup({ open, value, start, onClose, onPick }: { open: boolean; value: RecurrenceRule | null; start: number; onClose: () => void; onPick: (r: RecurrenceRule | null) => void }) {
  const [r, setR] = useState<RecurrenceRule | null>(value);
  const [custom, setCustom] = useState(false);
  const [untilPick, setUntilPick] = useState(false);
  useEffect(() => { if (open) { setR(value); setCustom(false); } }, [open, value]);
  const wd = weekday(start);
  const presets: { label: string; rule: RecurrenceRule | null }[] = [
    { label: 'しない', rule: null },
    { label: '毎日', rule: { freq: 'daily', interval: 1, byWeekday: null, until: r?.until ?? null } },
    { label: '毎週', rule: { freq: 'weekly', interval: 1, byWeekday: [wd], until: r?.until ?? null } },
    { label: '平日', rule: { freq: 'weekly', interval: 1, byWeekday: [1, 2, 3, 4, 5], until: r?.until ?? null } },
    { label: '隔週', rule: { freq: 'weekly', interval: 2, byWeekday: [wd], until: r?.until ?? null } },
    { label: '毎月', rule: { freq: 'monthly', interval: 1, byWeekday: null, until: r?.until ?? null } },
  ];
  const same = (a: RecurrenceRule | null, b: RecurrenceRule | null) => JSON.stringify(a && { ...a, until: null }) === JSON.stringify(b && { ...b, until: null });
  return (
    <Popup open={open} title="繰り返し" onClose={onClose} onDone={() => onPick(r && r.freq === 'weekly' && !r.byWeekday?.length ? { ...r, byWeekday: [wd] } : r)} testId="repeat-popup" tall>
      <div className="group"><div className="group-body">
        {presets.map((p) => (
          <button key={p.label} type="button" role="menuitemradio" aria-checked={!custom && same(r, p.rule)} className="row row-button" onClick={() => { setCustom(false); setR(p.rule); }}>
            <span className="row-label">{p.label}</span>
            {!custom && same(r, p.rule) && <Icon name="check" size={18} strokeWidth={2.6} className="tint" />}
          </button>
        ))}
        <button type="button" className="row row-button" aria-expanded={custom} onClick={() => { setCustom(true); setR(r ?? { freq: 'weekly', interval: 1, byWeekday: [wd], until: null }); }} data-testid="repeat-custom">
          <span className="row-label">カスタム</span>
          <Icon name="chevronRight" size={16} className="chev" />
        </button>
      </div></div>
      {(custom || (r && !presets.some((p) => same(r, p.rule)))) && r && (
        <div className="group" data-testid="repeat-custom-panel"><div className="group-body">
          <div className="row">
            <span className="row-label">頻度</span>
            <span className="seg-mini">
              {(['daily', 'weekly', 'monthly'] as const).map((f) => <button key={f} type="button" aria-pressed={r.freq === f} onClick={() => setR({ ...r, freq: f, byWeekday: f === 'weekly' ? r.byWeekday ?? [wd] : null })}>{{ daily: '日', weekly: '週', monthly: '月' }[f]}</button>)}
            </span>
          </div>
          <div className="row">
            <span className="row-label">間隔</span>
            <span className="stepper">
              <button type="button" aria-label="間隔を減らす" onClick={() => setR({ ...r, interval: Math.max(1, r.interval - 1) })}><Icon name="chevronLeft" size={16} /></button>
              <span data-testid="repeat-interval">{r.interval}{r.freq === 'daily' ? '日' : r.freq === 'weekly' ? '週' : 'か月'}ごと</span>
              <button type="button" aria-label="間隔を増やす" onClick={() => setR({ ...r, interval: Math.min(99, r.interval + 1) })}><Icon name="chevronRight" size={16} /></button>
            </span>
          </div>
          {r.freq === 'weekly' && (
            <div className="row">
              <span className="wd-circles" role="group" aria-label="曜日">
                {WD.map((w, i) => (
                  <button key={w} type="button" aria-pressed={r.byWeekday?.includes(i) ?? false} onClick={() => setR({ ...r, byWeekday: r.byWeekday?.includes(i) ? r.byWeekday.filter((x) => x !== i) : [...(r.byWeekday ?? []), i] })}>{w}</button>
                ))}
              </span>
            </div>
          )}
        </div></div>
      )}
      {r && (
        <div className="group"><div className="group-body">
          <div className="row">
            <span className="row-label">終了</span>
            <span className="seg-mini">
              <button type="button" aria-pressed={r.until == null} onClick={() => setR({ ...r, until: null })}>なし</button>
              <button type="button" aria-pressed={r.until != null} onClick={() => setUntilPick(true)}>{r.until != null ? `${new Date(r.until).getMonth() + 1}/${new Date(r.until).getDate()}まで` : '日付'}</button>
            </span>
          </div>
        </div></div>
      )}
      <DatePickerPopup open={untilPick} value={r?.until ?? addDays(start, 90)} min={start} title="繰り返しの終了日" onClose={() => setUntilPick(false)} onPick={(d) => { setUntilPick(false); if (r) setR({ ...r, until: d + 86_400_000 - 1 }); }} />
    </Popup>
  );
}

// ---------------- アイコン・色（Q68・Q76） ----------------
const ICON_GROUPS: { title: string; ids: ItemIconId[] }[] = [
  { title: '学習・仕事', ids: ['book', 'books', 'pencil', 'note', 'laptop', 'flask', 'graduation', 'briefcase', 'target', 'bulb'] },
  { title: '生活', ids: ['house', 'cart', 'pan', 'dining', 'sparkles', 'heart', 'person'] },
  { title: '趣味・移動', ids: ['run', 'music', 'headphones', 'plane', 'chat', 'star'] },
  { title: '予定', ids: ['calendar', 'circle'] },
];

export function IconStrip({ value, onChange, recent, target }: { value: string; onChange: (id: ItemIconId) => void; recent: string[]; target: 'task' | 'event' }) {
  const [all, setAll] = useState(false);
  const [q, setQ] = useState('');
  const sel = resolveItemIcon(value).id;
  const base = target === 'task' ? TASK_ICON_CHOICES : CALENDAR_ICON_CHOICES;
  const strip = [...new Set([sel, ...recent.filter((r) => r in ITEM_ICONS), ...base])].slice(0, 14) as ItemIconId[];
  const matches = useMemo(() => {
    const k = q.trim();
    return ICON_GROUPS.map((g) => ({ ...g, ids: g.ids.filter((id) => !k || ITEM_ICONS[id].includes(k) || id.includes(k.toLowerCase())) })).filter((g) => g.ids.length);
  }, [q]);
  return (
    <>
      <div className="hstrip" role="radiogroup" aria-label="アイコン" data-testid="icon-strip">
        {strip.map((id) => (
          <button key={id} type="button" role="radio" aria-checked={id === sel} aria-label={ITEM_ICONS[id]} className={`hcircle ${id === sel ? 'on' : ''}`} onClick={() => onChange(id)} data-testid={`icon-${id}`}>
            <Icon name={id} size={20} strokeWidth={id === sel ? 2.2 : 1.8} />
          </button>
        ))}
        <button type="button" className="hcircle more" onClick={() => setAll(true)} aria-label="すべてのアイコン" data-testid="icon-more"><Icon name="more" size={20} strokeWidth={3} /></button>
      </div>
      <Popup open={all} title="アイコン" onClose={() => setAll(false)} testId="icon-all" tall>
        <div className="search-field"><Icon name="search" size={17} /><input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="名前で探す" aria-label="アイコンを検索" /></div>
        {recent.length > 0 && !q && (
          <><div className="group-header">最近使用</div>
            <div className="icon-grid">{recent.filter((r) => r in ITEM_ICONS).slice(0, 8).map((id) => <button key={id} type="button" className={`icon-choice ${id === sel ? 'on' : ''}`} aria-label={ITEM_ICONS[id as ItemIconId]} onClick={() => { onChange(id as ItemIconId); setAll(false); }}><Icon name={id as ItemIconId} size={22} /></button>)}</div></>
        )}
        {matches.map((g) => (
          <div key={g.title}>
            <div className="group-header">{g.title}</div>
            <div className="icon-grid">{g.ids.map((id) => <button key={id} type="button" className={`icon-choice ${id === sel ? 'on' : ''}`} aria-label={ITEM_ICONS[id]} onClick={() => { onChange(id); setAll(false); }} data-testid={`icon-all-${id}`}><Icon name={id} size={22} /></button>)}</div>
          </div>
        ))}
        {matches.length === 0 && <p className="muted center">見つかりません</p>}
      </Popup>
    </>
  );
}

export const COLORS = ['#0A84FF', '#5E5CE6', '#BF5AF2', '#FF2D55', '#FF3B30', '#FF9500', '#FFCC00', '#34C759', '#30B0C7', '#64D2FF', '#A2845E', '#8E8E93'];
export function ColorStrip({ value, onChange, recent }: { value: string | null; onChange: (c: string | null) => void; recent: string[] }) {
  const list = [...new Set([...recent.filter((c) => /^#[0-9a-f]{6}$/i.test(c)), ...COLORS])].slice(0, 16);
  return (
    <div className="hstrip" role="radiogroup" aria-label="色" data-testid="color-strip">
      <button type="button" role="radio" aria-checked={value == null} className={`hcircle ${value == null ? 'on' : ''}`} aria-label="カレンダーの色" onClick={() => onChange(null)}><Icon name="calendar" size={18} /></button>
      {list.map((c) => (
        <button key={c} type="button" role="radio" aria-checked={value?.toLowerCase() === c.toLowerCase()} aria-label={`色 ${c}`} className={`hcircle color ${value?.toLowerCase() === c.toLowerCase() ? 'on' : ''}`} style={{ ['--c' as string]: c }} onClick={() => onChange(c)} />
      ))}
      <label className="hcircle custom" aria-label="カスタムの色">
        <Icon name="paint" size={18} />
        <input type="color" value={value ?? '#0A84FF'} onChange={(e) => onChange(e.target.value.toUpperCase())} />
      </label>
    </div>
  );
}

// ---------------- 通知（Q79） ----------------
const NOTIFY_PRESETS = [0, 5, 10, 15, 30, 60, 120, 1440];
export const notifyLabel = (m: number) => (m === 0 ? '開始時刻' : m % 1440 === 0 ? `${m / 1440}日前` : m % 60 === 0 ? `${m / 60}時間前` : m >= 60 ? `${Math.floor(m / 60)}時間${m % 60}分前` : `${m}分前`);
export function NotifyPopup({ open, value, onClose, onPick, permission }: { open: boolean; value: number[]; onClose: () => void; onPick: (v: number[]) => void; permission: string }) {
  const [v, setV] = useState<number[]>(value);
  const [d, setD] = useState(0);
  const [h, setH] = useState(0);
  const [m, setM] = useState(30);
  useEffect(() => { if (open) setV(value); }, [open, value]);
  const toggle = (x: number) => setV((l) => (l.includes(x) ? l.filter((y) => y !== x) : [...l, x].sort((a, b) => a - b).slice(0, 10)));
  return (
    <Popup open={open} title="通知" onClose={onClose} onDone={() => onPick(v)} testId="notify-popup" tall>
      {permission !== 'granted' && <p className="note-text" role="status">{permission === 'denied' ? '通知はブラウザーの設定でオフになっています。設定は保存されますが、届きません。' : permission === 'unsupported' ? 'この環境は通知に対応していません。設定は保存されます。' : '通知を受け取るには「その他」の「通知とお知らせ」で許可してください。'}</p>}
      <div className="group"><div className="group-body">
        {NOTIFY_PRESETS.map((x) => (
          <button key={x} type="button" role="menuitemcheckbox" aria-checked={v.includes(x)} className="row row-button" onClick={() => toggle(x)}>
            <span className="row-label">{notifyLabel(x)}</span>
            {v.includes(x) && <Icon name="check" size={18} strokeWidth={2.6} className="tint" />}
          </button>
        ))}
        {v.filter((x) => !NOTIFY_PRESETS.includes(x)).map((x) => (
          <button key={x} type="button" role="menuitemcheckbox" aria-checked className="row row-button" onClick={() => toggle(x)}>
            <span className="row-label">{notifyLabel(x)}</span><Icon name="check" size={18} strokeWidth={2.6} className="tint" />
          </button>
        ))}
      </div></div>
      <div className="group-header">自由に指定</div>
      <div className="group"><div className="group-body"><div className="row">
        <span className="dur-inputs">
          <label><input type="number" inputMode="numeric" min={0} max={27} value={d} onChange={(e) => setD(Math.max(0, Math.min(27, Number(e.target.value) || 0)))} aria-label="日" />日</label>
          <label><input type="number" inputMode="numeric" min={0} max={23} value={h} onChange={(e) => setH(Math.max(0, Math.min(23, Number(e.target.value) || 0)))} aria-label="時間" />時間</label>
          <label><input type="number" inputMode="numeric" min={0} max={59} value={m} onChange={(e) => setM(Math.max(0, Math.min(59, Number(e.target.value) || 0)))} aria-label="分" />分前</label>
        </span>
        <button type="button" className="gpill glass glass-i" onClick={() => toggle(d * 1440 + h * 60 + m)} data-testid="notify-add-custom">追加</button>
      </div></div></div>
    </Popup>
  );
}

// ---------------- 場所（Q78）：履歴と手入力。地図検索は OpenStreetMap（Nominatim）を検索ボタンのときだけ ----------------
interface NominatimHit { display_name: string; name?: string; lat: string; lon: string }
export function PlacePopup({ open, value, history, onClose, onPick }: { open: boolean; value: PlaceValue | null; history: PlaceValue[]; onClose: () => void; onPick: (p: PlaceValue | null) => void }) {
  const [q, setQ] = useState('');
  const [hits, setHits] = useState<PlaceValue[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');
  const [manual, setManual] = useState<PlaceValue>({ name: '', address: '', lat: null, lng: null });
  const last = useRef(0);
  useEffect(() => { if (open) { setQ(value?.name ?? ''); setHits(null); setErr(''); setManual(value ?? { name: '', address: '', lat: null, lng: null }); } }, [open, value]);
  const search = async () => {
    const k = q.trim();
    if (!k) return;
    // 利用規約：1秒に1回まで・入力のたびには問い合わせない
    const wait = 1100 - (Date.now() - last.current);
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    last.current = Date.now();
    setBusy(true); setErr('');
    try {
      const res = await fetch(`https://nominatim.openstreetmap.org/search?format=jsonv2&limit=8&accept-language=ja&q=${encodeURIComponent(k)}`, { headers: { accept: 'application/json' } });
      if (!res.ok) throw new Error(String(res.status));
      const list = (await res.json()) as NominatimHit[];
      setHits(list.map((h) => ({ name: h.name || h.display_name.split(',')[0]!.trim(), address: h.display_name, lat: Number(h.lat), lng: Number(h.lon) })));
    } catch {
      setErr('地図の検索に失敗しました。下の欄に手で入力できます。');
    } finally { setBusy(false); }
  };
  const k = q.trim();
  const fromHistory = history.filter((h) => !k || h.name.includes(k) || h.address.includes(k)).slice(0, 8);
  return (
    <Popup open={open} title="場所" onClose={onClose} testId="place-popup" tall>
      <form className="search-field" onSubmit={(e) => { e.preventDefault(); void search(); }}>
        <Icon name="search" size={17} />
        <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="場所の名前・住所" aria-label="場所を検索" data-testid="place-query" />
        <button type="submit" className="gpill glass glass-i" disabled={!k || busy} data-testid="place-search">{busy ? '検索中' : '地図で検索'}</button>
      </form>
      <p className="muted small">地図の検索には OpenStreetMap を使います（入力した語が送られます）。</p>
      {fromHistory.length > 0 && <><div className="group-header">履歴</div><div className="group"><div className="group-body">
        {fromHistory.map((p, i) => <button key={i} type="button" className="row row-button" onClick={() => onPick(p)}><Icon name="clock" size={18} className="muted" /><span className="row-label">{p.name}<span className="sub-label">{p.address}</span></span></button>)}
      </div></div></>}
      {err && <p className="form-error" role="alert">{err}</p>}
      {hits && <><div className="group-header">検索結果</div><div className="group"><div className="group-body" data-testid="place-hits">
        {hits.length === 0 && <div className="row muted">見つかりませんでした</div>}
        {hits.map((p, i) => <button key={i} type="button" className="row row-button" onClick={() => onPick(p)}><Icon name="flag" size={18} className="tint" /><span className="row-label">{p.name}<span className="sub-label">{p.address}</span></span></button>)}
      </div></div></>}
      <div className="group-header">手で入力</div>
      <div className="group"><div className="group-body">
        <input className="row-input" value={manual.name} onChange={(e) => setManual({ ...manual, name: e.target.value })} placeholder="名称" aria-label="場所の名称" data-testid="place-name" />
        <input className="row-input" value={manual.address} onChange={(e) => setManual({ ...manual, address: e.target.value })} placeholder="住所（任意）" aria-label="住所" />
        <button type="button" className="row row-button center tint" disabled={!manual.name.trim()} onClick={() => onPick({ ...manual, name: manual.name.trim(), address: manual.address.trim() })} data-testid="place-use-manual">この場所にする</button>
      </div></div>
      {value && <button type="button" className="row row-button center destructive" onClick={() => onPick(null)}>場所を外す</button>}
    </Popup>
  );
}
