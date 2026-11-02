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
