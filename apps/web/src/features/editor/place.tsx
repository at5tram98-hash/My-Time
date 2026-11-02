import { useEffect, useRef, useState } from 'react';
import { AnimatePresence, motion, useReducedMotion } from 'motion/react';
import type { PlaceValue } from '@my-time/domain';
import { Icon } from '../../components/Icon';
import { Popup } from '../../ui/Popup';
import { useUIActions } from '../../app/ui';

interface NominatimHit { name?: string; display_name: string; lat: string; lon: string }

const TRAVEL = [5, 10, 15, 30, 45, 60];
const hm = (t: number) => { const d = new Date(t); return `${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`; };
export const travelLabel = (m: number | null | undefined) => (m == null ? '' : m === 0 ? '移動なし' : m >= 60 && m % 60 === 0 ? `移動${m / 60}時間` : `移動${m}分`);

/** 場所と移動の要約（基本タブの行・情報確認で共通） */
export function placeSummary(place: PlaceValue | null, travel: number | null): string {
  if (!place && travel == null) return '場所を追加';
  return [place?.name, travelLabel(travel)].filter(Boolean).join(' · ');
}

/** 1秒1回まで・明示操作のときだけ・古い応答で新しい結果を上書きしない、場所検索（C16） */
function usePlaceSearch() {
  const last = useRef(0);
  const seq = useRef(0);
  const ctrl = useRef<AbortController | null>(null);
  const [state, setState] = useState<{ kind: 'idle' } | { kind: 'busy' } | { kind: 'done'; hits: PlaceValue[] } | { kind: 'offline' } | { kind: 'failed' }>({ kind: 'idle' });
  const run = async (q: string) => {
    const k = q.trim();
    if (!k) return;
    const my = ++seq.current;
    ctrl.current?.abort();
    if (typeof navigator !== 'undefined' && navigator.onLine === false) return setState({ kind: 'offline' });
    setState({ kind: 'busy' });
    const wait = 1100 - (Date.now() - last.current);
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    if (my !== seq.current) return;
    last.current = Date.now();
    const c = new AbortController();
    ctrl.current = c;
    try {
      const res = await fetch(`https://nominatim.openstreetmap.org/search?format=jsonv2&limit=8&accept-language=ja&q=${encodeURIComponent(k)}`, { headers: { accept: 'application/json' }, signal: c.signal });
      if (!res.ok) throw new Error(String(res.status));
      const list = (await res.json()) as NominatimHit[];
      if (my !== seq.current) return;
      setState({ kind: 'done', hits: list.map((h) => ({ name: h.name || h.display_name.split(',')[0]!.trim(), address: h.display_name, lat: Number(h.lat), lng: Number(h.lon) })) });
    } catch (e) {
      if ((e as Error).name === 'AbortError' || my !== seq.current) return;
      setState(navigator.onLine === false ? { kind: 'offline' } : { kind: 'failed' });
    }
  };
  const reset = () => { seq.current++; ctrl.current?.abort(); setState({ kind: 'idle' }); };
  return { state, run, reset };
}

/**
 * 場所と移動（C14〜C17）。検索・履歴・住所の直接入力と、移動時間を1つのシートで編集し、
 * 「完了」で両方をまとめて反映、「キャンセル」で両方とも元に戻す。
 */
export function PlaceTravelPopup({ open, place, travel, start, history, onClose, onPick }: { open: boolean; place: PlaceValue | null; travel: number | null; start: number | null; history: PlaceValue[]; onClose: () => void; onPick: (p: PlaceValue | null, travel: number | null) => void }) {
  const reduce = useReducedMotion();
  const { confirm } = useUIActions();
  const [p, setP] = useState<PlaceValue | null>(place);
  const [t, setT] = useState<number | null>(travel);
  const [q, setQ] = useState('');
  const [manualOpen, setManualOpen] = useState(false);
  const [manual, setManual] = useState<PlaceValue>({ name: '', address: '', lat: null, lng: null });
  const [custom, setCustom] = useState('');
  const composing = useRef(false);
  const s = usePlaceSearch();
  useEffect(() => {
    if (!open) return;
    setP(place); setT(travel); setQ(''); setManualOpen(false); s.reset();
    setManual(place && place.lat == null ? place : { name: '', address: '', lat: null, lng: null });
    setCustom(travel != null && !TRAVEL.includes(travel) && travel !== 0 ? String(travel) : '');
  }, [open]); // eslint-disable-line react-hooks/exhaustive-deps
  const k = q.trim();
  const fromHistory = history.filter((h) => !k || h.name.includes(k) || h.address.includes(k)).slice(0, 6);
  const choose = (v: PlaceValue) => { setP(v); setQ(''); s.reset(); setManualOpen(false); };
  const removePlace = async () => {
    if (t != null && t > 0 && (await confirm({ title: '移動時間も外しますか？', message: `場所を外します。設定中の「${travelLabel(t)}」をどうするか選んでください。`, confirmLabel: '移動時間も外す', cancelLabel: '移動時間は残す' }))) setT(null);
    setP(null);
  };
  const depart = start != null && t != null && t > 0 ? start - t * 60_000 : null;
  const anim = reduce ? { initial: { opacity: 0 }, animate: { opacity: 1 }, exit: { opacity: 0 } } : { initial: { opacity: 0, y: 8 }, animate: { opacity: 1, y: 0 }, exit: { opacity: 0, y: -4 } };
  return (
    <Popup open={open} title="場所と移動" onClose={onClose} onDone={() => onPick(p, t)} testId="place-popup" tall>
      {p && (
        <div className="place-current" data-testid="place-current">
          <span className="place-pin" aria-hidden><Icon name="pin" size={18} /></span>
          <span className="place-current-text"><strong>{p.name}</strong>{p.address && <span className="muted small">{p.address}</span>}</span>
        </div>
      )}
      <form className="csearch" role="search" onSubmit={(e) => { e.preventDefault(); if (!composing.current) void s.run(q); }}>
        <Icon name="search" size={17} className="muted" />
        <input
          type="search"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onCompositionStart={() => { composing.current = true; }}
          onCompositionEnd={() => { composing.current = false; }}
          placeholder="場所や住所を検索"
          aria-label="場所や住所を検索"
          enterKeyHint="search"
          data-testid="place-query"
        />
        {q && <button type="button" className="csearch-clear" aria-label="入力を消す" onClick={() => { setQ(''); s.reset(); }}><Icon name="close" size={13} strokeWidth={2.6} /></button>}
        <button type="submit" className="csearch-go" aria-label="検索" disabled={!k || s.state.kind === 'busy'} data-testid="place-search"><Icon name="search" size={16} strokeWidth={2.4} /></button>
      </form>

      <AnimatePresence mode="popLayout" initial={false}>
        {s.state.kind === 'busy' && (
          <motion.div key="busy" className="group" {...anim}><div className="group-body" aria-busy="true" aria-label="検索中">
            {[0, 1, 2].map((i) => <div key={i} className="row skel-row"><span className="skel skel-ico" /><span className="skel skel-line" /></div>)}
          </div></motion.div>
        )}
        {s.state.kind === 'done' && (
          <motion.div key="hits" {...anim}>
            <div className="group"><div className="group-body" data-testid="place-hits">
              {s.state.hits.length === 0 && <div className="row muted">見つかりませんでした。別の言葉で探すか、住所を直接入力してください。</div>}
              {s.state.hits.map((h, i) => <button key={i} type="button" className="row row-button place-row" onClick={() => choose(h)}><span className="place-pin small" aria-hidden><Icon name="pin" size={15} /></span><span className="row-label">{h.name}<span className="sub-label">{h.address}</span></span></button>)}
            </div></div>
            <p className="map-credit">地図データ © OpenStreetMap contributors</p>
          </motion.div>
        )}
        {(s.state.kind === 'failed' || s.state.kind === 'offline') && (
          <motion.div key="err" className="place-err" role="alert" {...anim}>
            <span>{s.state.kind === 'offline' ? 'オフラインのため検索できません。' : '検索できませんでした。'}</span>
            <span className="place-err-actions">
              {s.state.kind === 'failed' && <button type="button" className="link-btn" onClick={() => void s.run(q)}>もう一度</button>}
              <button type="button" className="link-btn" onClick={() => { setManualOpen(true); setManual((m) => ({ ...m, name: m.name || k })); }}>住所を直接入力</button>
            </span>
          </motion.div>
        )}
      </AnimatePresence>

      {s.state.kind !== 'done' && fromHistory.length > 0 && (
        <>
          <div className="group-header">履歴</div>
          <div className="group"><div className="group-body">
            {fromHistory.map((h, i) => <button key={i} type="button" className="row row-button place-row" onClick={() => choose(h)}><Icon name="clock" size={18} className="muted" /><span className="row-label">{h.name}{h.address && <span className="sub-label">{h.address}</span>}</span></button>)}
          </div></div>
        </>
      )}

      <div className="group"><div className="group-body">
        <button type="button" className="row row-button" aria-expanded={manualOpen} onClick={() => setManualOpen((o) => !o)} data-testid="place-manual-toggle">
          <Icon name="pencil" size={18} className="tint" /><span className="row-label tint">住所を直接入力</span>
          <Icon name="chevronDown" size={16} className={`chev ${manualOpen ? 'open' : ''}`} />
        </button>
        <AnimatePresence initial={false}>
          {manualOpen && (
            <motion.div key="m" className="place-manual" initial={reduce ? { opacity: 0 } : { opacity: 0, height: 0 }} animate={reduce ? { opacity: 1 } : { opacity: 1, height: 'auto' }} exit={reduce ? { opacity: 0 } : { opacity: 0, height: 0 }} transition={{ duration: 0.22 }}>
              <label className="field"><span className="field-label">名称</span><input className="row-input" value={manual.name} onChange={(e) => setManual({ ...manual, name: e.target.value })} placeholder="例：図書館" data-testid="place-name" /></label>
              <label className="field"><span className="field-label">住所（任意）</span><input className="row-input" value={manual.address} onChange={(e) => setManual({ ...manual, address: e.target.value })} placeholder="例：京都市北区上賀茂本山" /></label>
              <button type="button" className="gbtn-primary glass-i block" disabled={!manual.name.trim()} onClick={() => choose({ ...manual, name: manual.name.trim(), address: manual.address.trim(), lat: null, lng: null })} data-testid="place-use-manual">この場所を使う</button>
            </motion.div>
          )}
        </AnimatePresence>
      </div></div>

      <div className="group-header">移動時間</div>
      <div className="group"><div className="group-body padded">
        <div className="travel-btns" role="group" aria-label="移動時間">
          <button type="button" className="chip-opt" aria-pressed={t == null || t === 0} onClick={() => { setT(null); setCustom(''); }}>なし</button>
          {TRAVEL.map((m) => <button key={m} type="button" className="chip-opt" aria-pressed={t === m} onClick={() => { setT(m); setCustom(''); }} data-testid={`travel-${m}`}>{m === 60 ? '1時間' : `${m}分`}</button>)}
        </div>
        <label className="field inline"><span className="field-label">ほかの時間（分）</span><input className="row-input num" type="number" inputMode="numeric" min={1} max={1440} value={custom} onChange={(e) => { setCustom(e.target.value); const n = Number(e.target.value); setT(e.target.value === '' ? null : Number.isFinite(n) && n > 0 ? Math.min(1440, Math.round(n)) : null); }} aria-label="移動時間（分）" data-testid="travel-custom" /></label>
        {depart != null && <p className="muted small">出発の目安 {hm(depart)}（予定の時刻は変わりません）</p>}
      </div></div>

      {p && <div className="group"><div className="group-body"><button type="button" className="row row-button center destructive" onClick={() => void removePlace()} data-testid="place-remove">場所を削除</button></div></div>}
    </Popup>
  );
}

/** OSM タイルから計算する静的な地図プレビュー（C06）。座標がないときは架空のピンを置かない */
export function MapPreview({ place, onSearch }: { place: PlaceValue; onSearch?: () => void }) {
  const [failed, setFailed] = useState(false);
  const url = place.lat != null && place.lng != null ? `https://www.openstreetmap.org/?mlat=${place.lat}&mlon=${place.lng}#map=17/${place.lat}/${place.lng}` : `https://www.openstreetmap.org/search?query=${encodeURIComponent([place.name, place.address].filter(Boolean).join(' '))}`;
  if (place.lat == null || place.lng == null) {
    return (
      <div className="map-card nomap" data-testid="map-fallback">
        <div className="map-text"><strong>{place.name}</strong>{place.address && <span className="muted small">{place.address}</span>}</div>
        <div className="map-actions">
          {onSearch && <button type="button" className="link-btn" onClick={onSearch}>地図で確認</button>}
          <a className="link-btn" href={url} target="_blank" rel="noreferrer noopener">マップで開く</a>
        </div>
      </div>
    );
  }
  const z = 16;
  const n = 2 ** z;
  const xf = ((place.lng + 180) / 360) * n;
  const latR = (place.lat * Math.PI) / 180;
  const yf = ((1 - Math.log(Math.tan(latR) + 1 / Math.cos(latR)) / Math.PI) / 2) * n;
  const x0 = Math.floor(xf) - 1;
  const y0 = Math.floor(yf) - 1;
  const px = (xf - x0) * 256;
  const py = (yf - y0) * 256;
  return (
    <div className="map-card" data-testid="map-preview">
      <a className="map-view" href={url} target="_blank" rel="noreferrer noopener" aria-label={`${place.name}の地図を開く`}>
        {!failed ? (
          <span className="map-tiles" style={{ transform: `translate(calc(50% - ${px}px), calc(72px - ${py}px))` }} aria-hidden>
            {[0, 1, 2].map((j) => [0, 1, 2].map((i) => <img key={`${i}-${j}`} alt="" loading="lazy" width={256} height={256} style={{ left: i * 256, top: j * 256 }} src={`https://tile.openstreetmap.org/${z}/${x0 + i}/${y0 + j}.png`} onError={() => setFailed(true)} />))}
          </span>
        ) : <span className="map-off" aria-hidden><Icon name="pin" size={22} /></span>}
        <span className="map-pin" aria-hidden><Icon name="pin" size={26} strokeWidth={2.2} /></span>
        <span className="map-credit-in">© OpenStreetMap</span>
      </a>
      <div className="map-text"><strong>{place.name}</strong>{place.address && <span className="muted small">{place.address}</span>}</div>
      <a className="link-btn map-open" href={url} target="_blank" rel="noreferrer noopener">マップで開く</a>
    </div>
  );
}
