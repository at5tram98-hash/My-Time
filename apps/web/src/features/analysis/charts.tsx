import { useId, useState } from 'react';
import { formatDuration } from '@my-time/domain';

export interface ChartPoint { label: string; bar: number; line: number | null; barText: string; lineText?: string }

/**
 * 棒（実行時間など）と折れ線（完了率など）を重ねたグラフ。
 * 指でなぞる／タップで値を表示し、同じ値を表でも読めるようにする（Q47・Q50）。
 */
export function ComboChart({ points, barLabel, lineLabel, height = 150, testId, highlight }: { points: ChartPoint[]; barLabel: string; lineLabel?: string; height?: number; testId?: string; highlight?: number }) {
  const [sel, setSel] = useState<number | null>(null);
  const [table, setTable] = useState(false);
  const id = useId();
  const n = points.length;
  const W = 320;
  const H = height;
  const top = 18;
  const bottom = 18;
  const maxBar = Math.max(1, ...points.map((p) => p.bar));
  const step = W / Math.max(1, n);
  const bw = Math.max(3, Math.min(26, step * 0.6));
  const y = (v: number) => top + (H - top - bottom) * (1 - v);
  const linePts = points.map((p, i) => (p.line == null ? null : [i * step + step / 2, y(Math.max(0, Math.min(1, p.line)))] as const));
  const path = linePts.reduce((acc, p, i) => (p ? `${acc}${acc && linePts[i - 1] ? 'L' : 'M'}${p[0].toFixed(1)},${p[1].toFixed(1)}` : acc), '');
  const pick = (e: React.PointerEvent<SVGSVGElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    const i = Math.floor(((e.clientX - r.left) / r.width) * n);
    setSel(Math.max(0, Math.min(n - 1, i)));
  };
  const s = sel != null ? points[sel] : null;
  const labelEvery = n > 14 ? Math.ceil(n / 7) : 1;
  const summary = `${barLabel}${lineLabel ? `と${lineLabel}` : ''}のグラフ。最大 ${points.reduce((m, p) => (p.bar > m.bar ? p : m), points[0] ?? { bar: 0, barText: '0', label: '' }).barText}`;
  return (
    <div className="chart" data-testid={testId}>
      <div className="chart-tip" aria-live="polite">
        {s ? <><b>{s.label}</b><span className="chart-key bar">{barLabel} {s.barText}</span>{lineLabel && <span className="chart-key line">{lineLabel} {s.lineText ?? '—'}</span>}</> : <span className="muted">グラフを指でなぞると値を表示します</span>}
      </div>
      <svg
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="none"
        role="img"
        aria-label={summary}
        aria-describedby={`${id}-t`}
        onPointerDown={(e) => { pick(e); try { e.currentTarget.setPointerCapture(e.pointerId); } catch { /* 無視 */ } }}
        onClick={(e) => pick(e as unknown as React.PointerEvent<SVGSVGElement>)}
        onPointerMove={(e) => { if (e.buttons || e.pointerType === 'mouse') pick(e); }}
        onPointerLeave={(e) => { if (e.pointerType === 'mouse') setSel(null); }}
        style={{ height: H, touchAction: 'pan-y' }}
      >
        {[0.5, 1].map((g) => <line key={g} x1={0} x2={W} y1={y(g)} y2={y(g)} className="chart-grid" />)}
        {points.map((p, i) => {
          const h = (H - top - bottom) * (p.bar / maxBar);
          return <rect key={i} x={i * step + (step - bw) / 2} y={H - bottom - h} width={bw} height={Math.max(p.bar > 0 ? 2 : 0, h)} rx={Math.min(4, bw / 2)} className={`chart-bar ${sel === i || highlight === i ? 'on' : ''}`} />;
        })}
        {path && <path d={path} className="chart-line" fill="none" vectorEffect="non-scaling-stroke" />}
        {linePts.map((p, i) => p && <circle key={i} cx={p[0]} cy={p[1]} r={sel === i ? 4 : 2.4} className="chart-dot" vectorEffect="non-scaling-stroke" />)}
        {sel != null && <line x1={sel * step + step / 2} x2={sel * step + step / 2} y1={top - 6} y2={H - bottom} className="chart-cursor" vectorEffect="non-scaling-stroke" />}
      </svg>
      <div className="chart-axis" style={{ gridTemplateColumns: `repeat(${n}, 1fr)` }} aria-hidden>
        {points.map((p, i) => <span key={i}>{i % labelEvery === 0 ? p.label : ''}</span>)}
      </div>
      <button type="button" className="link-btn small" aria-expanded={table} onClick={() => setTable(!table)}>{table ? '表を閉じる' : '表で見る'}</button>
      <table id={`${id}-t`} className={table ? 'chart-table' : 'sr-only'}>
        <thead><tr><th scope="col">区切り</th><th scope="col">{barLabel}</th>{lineLabel && <th scope="col">{lineLabel}</th>}</tr></thead>
        <tbody>{points.map((p, i) => <tr key={i}><th scope="row">{p.label}</th><td>{p.barText}</td>{lineLabel && <td>{p.lineText ?? '—'}</td>}</tr>)}</tbody>
      </table>
    </div>
  );
}

/** 曜日別・時間帯別などの小さな棒グラフ */
export function MiniBars({ values, labels, testId, title }: { values: number[]; labels: string[]; testId?: string; title: string }) {
  const max = Math.max(1, ...values);
  const best = values.indexOf(Math.max(...values));
  return (
    <div className="minibars" data-testid={testId} role="img" aria-label={`${title}。${values.some((v) => v > 0) ? `いちばん多いのは${labels[best]}（${formatDuration(values[best]!)}）` : '記録なし'}`}>
      {values.map((v, i) => (
        <div key={i} className={`mb-col ${i === best && v > 0 ? 'on' : ''}`}>
          <div className="mb-bar" style={{ height: `${Math.round((v / max) * 100)}%` }} />
          <span className="mb-label">{labels[i]}</span>
        </div>
      ))}
    </div>
  );
}

/** 予定と実績を並べた棒（C31 ③）。予定は枠線のみ、実績は塗り。色だけでなく線種と凡例で区別 */
export function PairBars({ items, testId }: { items: { label: string; a: number; b: number }[]; testId?: string }) {
  const [sel, setSel] = useState<number | null>(null);
  const [table, setTable] = useState(false);
  const max = Math.max(1, ...items.flatMap((i) => [i.a, i.b]));
  const every = items.length > 14 ? Math.ceil(items.length / 7) : 1;
  const s = sel != null ? items[sel] : null;
  return (
    <div className="chart" data-testid={testId}>
      <div className="chart-tip" aria-live="polite">
        {s ? <><b>{s.label}</b><span className="chart-key plan">予定 {formatDuration(s.a)}</span><span className="chart-key bar">実績 {formatDuration(s.b)}</span></> : <><span className="chart-key plan">予定時間</span><span className="chart-key bar">実行時間</span></>}
      </div>
      <div className="pairbars" role="img" aria-label={`予定と実績の比較。予定合計 ${formatDuration(items.reduce((x, i) => x + i.a, 0))}、実績合計 ${formatDuration(items.reduce((x, i) => x + i.b, 0))}`} style={{ gridTemplateColumns: `repeat(${items.length}, 1fr)` }}>
        {items.map((it, i) => (
          <button key={i} type="button" className={`pb-col ${sel === i ? 'on' : ''}`} onClick={() => setSel(sel === i ? null : i)} aria-label={`${it.label} 予定${formatDuration(it.a)} 実績${formatDuration(it.b)}`}>
            <span className="pb-bars"><span className="pb-plan" style={{ height: `${(it.a / max) * 100}%` }} /><span className="pb-act" style={{ height: `${(it.b / max) * 100}%` }} /></span>
            <span className="pb-label">{i % every === 0 ? it.label : ''}</span>
          </button>
        ))}
      </div>
      <button type="button" className="link-btn small" aria-expanded={table} onClick={() => setTable(!table)}>{table ? '表を閉じる' : '表で見る'}</button>
      {table && <table className="chart-table"><thead><tr><th scope="col">区切り</th><th scope="col">予定</th><th scope="col">実績</th></tr></thead><tbody>{items.map((it, i) => <tr key={i}><th scope="row">{it.label}</th><td>{formatDuration(it.a)}</td><td>{formatDuration(it.b)}</td></tr>)}</tbody></table>}
    </div>
  );
}

const WDJ = ['日', '月', '火', '水', '木', '金', '土'];
/** 曜日×時間帯のヒートマップ（C31 ⑤）。濃さと数値（タップで表示）で示す */
export function Heatmap({ heat, testId }: { heat: number[][]; testId?: string }) {
  const [sel, setSel] = useState<[number, number] | null>(null);
  const max = Math.max(1, ...heat.flat());
  return (
    <div className="heat" data-testid={testId}>
      <div className="chart-tip" aria-live="polite">{sel ? <><b>{WDJ[sel[0]]}曜 {sel[1] * 3}〜{sel[1] * 3 + 3}時</b><span>{formatDuration(heat[sel[0]]![sel[1]]!)}</span></> : <span className="muted">マスをタップすると時間を表示します</span>}</div>
      <div className="heat-grid" role="table" aria-label="曜日と時間帯ごとの実行時間">
        <span className="heat-corner" aria-hidden />
        {[0, 3, 6, 9, 12, 15, 18, 21].map((h) => <span key={h} className="heat-h" aria-hidden>{h}</span>)}
        {heat.map((row, d) => (
          <div key={d} className="heat-row" role="row">
            <span className="heat-d" role="rowheader">{WDJ[d]}</span>
            {row.map((v, i) => <button key={i} type="button" role="cell" className={`heat-cell ${sel && sel[0] === d && sel[1] === i ? 'on' : ''}`} style={{ ['--a' as string]: v ? 0.12 + 0.88 * (v / max) : 0 }} aria-label={`${WDJ[d]}曜 ${i * 3}時から ${formatDuration(v)}`} onClick={() => setSel([d, i])} />)}
          </div>
        ))}
      </div>
    </div>
  );
}

/** カテゴリー別の実行時間と完了件数（C31 ④） */
export function CategoryBars({ rows, colorOf, onPick }: { rows: { category: string | null; workedMs: number; done: number; total: number }[]; colorOf: (c: string | null) => string; onPick?: (c: string | null) => void }) {
  const max = Math.max(1, ...rows.map((r) => r.workedMs));
  return (
    <div className="catbars" data-testid="by-category">
      {rows.map((r) => (
        <button key={r.category ?? '__none'} type="button" className="catbar" onClick={() => onPick?.(r.category)}>
          <span className="catbar-head"><span className="catbar-name"><span className="dot" style={{ background: colorOf(r.category) }} aria-hidden />{r.category ?? 'カテゴリーなし'}</span><span className="catbar-val">{formatDuration(r.workedMs)} · 完了 {r.done}/{r.total}</span></span>
          <span className="catbar-track"><span className="catbar-fill" style={{ width: `${(r.workedMs / max) * 100}%`, background: colorOf(r.category) }} /></span>
        </button>
      ))}
    </div>
  );
}
