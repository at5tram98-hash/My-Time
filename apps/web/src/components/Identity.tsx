import { resolveItemIcon, type ItemIconId } from '@my-time/domain';
import { Icon } from './Icon';

/**
 * 予定とタスクの共通アイコン体系（D3・C04・C05・C25・C28）。
 * - タスク：円の背景。実行は赤、確認は青（完了しても種別色を変えない）。
 * - 予定：角丸四角の背景。カレンダー（または予定）の色。
 * - リング：外周の円弧だけを absolute で重ね、中央の図形は通常の grid 中央に置く（子孫 svg へ配置指定を継承しない）。
 */

export type TaskKindTone = 'do' | 'check';
export const kindColor = (k: TaskKindTone) => (k === 'check' ? 'var(--check)' : 'var(--do)');
export const KIND_LABEL: Record<TaskKindTone, string> = { do: '実行', check: '確認' };

/** 太さはサイズで段階的に（D3：通常 1.8〜2.0、小さい表示 2.0〜2.2） */
const glyphStroke = (px: number) => (px <= 14 ? 2.3 : px <= 18 ? 2.1 : 1.9);

interface RingProps {
  /** 0〜1。null は未入力（0%として描かない） */
  value: number | null;
  size: number;
  color: string;
  track?: boolean;
}

/** 外周の円弧（中央の図形とは別レイヤー） */
export function RingArc({ value, size, color, track = true }: RingProps) {
  const stroke = Math.max(2.5, Math.round((size / 11) * 2) / 2);
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const v = value == null ? 0 : Math.max(0, Math.min(1, value));
  return (
    <svg className="ring-arc" width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden>
      {track && <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke="var(--ring-track)" strokeWidth={stroke} />}
      {v > 0 && <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeDasharray={`${c * v} ${c}`} transform={`rotate(-90 ${size / 2} ${size / 2})`} style={{ transition: 'stroke-dasharray 320ms var(--spring)' }} />}
    </svg>
  );
}

export interface TaskBadgeProps {
  icon: string | null | undefined;
  kind: TaskKindTone;
  size?: number;
  /** 外周に描く進捗（実績）。省略で外周なし */
  progress?: number | null;
  /** 理想進捗（実績とは別の色・細い円弧で示す） */
  ideal?: number | null;
  done?: boolean;
  delayed?: boolean;
  running?: boolean;
  /** アクセシブル名。省略時は装飾扱い */
  label?: string;
  className?: string;
}

/** タスクの識別バッジ（円）。外周の円弧と中央の図形を常に同じ中心に置く */
export function TaskBadge({ icon, kind, size = 40, progress, ideal, done, delayed, running, label, className = '' }: TaskBadgeProps) {
  const color = kindColor(kind);
  const ri = resolveItemIcon(icon);
  const hasRing = progress !== undefined || ideal !== undefined;
  const ringV = done ? 1 : progress ?? null;
  const inner = hasRing ? Math.round(size * 0.74) : size;
  const glyph = Math.round(inner * 0.52);
  let center: React.ReactNode;
  if (done) center = <Icon name="check" size={Math.round(inner * 0.5)} strokeWidth={3} />;
  else if (delayed) center = <Icon name="exclamation" size={Math.round(inner * 0.5)} strokeWidth={3} />;
  else center = <Icon name={ri.id} size={glyph} strokeWidth={glyphStroke(glyph)} />;
  return (
    <span
      className={`ident ident-task ${done ? 'is-done' : ''} ${delayed && !done ? 'is-delayed' : ''} ${running ? 'is-running' : ''} ${className}`}
      style={{ width: size, height: size, ['--k' as string]: color }}
      data-kind={kind}
      data-icon={ri.id}
      data-icon-source={ri.current ? 'id' : ri.legacy ? 'legacy' : 'fallback'}
      {...(label ? { role: 'img', 'aria-label': label } : { 'aria-hidden': true })}
    >
      {hasRing && <RingArc value={ringV} size={size} color={done ? color : delayed ? 'var(--orange)' : color} />}
      {hasRing && ideal != null && ideal > 0 && !done && <IdealTick value={ideal} size={size} />}
      <span className="ident-disc" style={{ width: inner, height: inner }}>{center}</span>
    </span>
  );
}

/** 理想進捗の位置を外周上の小さな目盛りで示す（実績の円弧とは別の指標） */
function IdealTick({ value, size }: { value: number; size: number }) {
  const v = Math.max(0, Math.min(1, value));
  const a = v * 2 * Math.PI - Math.PI / 2;
  const r = size / 2 - Math.max(2.5, size / 11) / 2;
  const x = size / 2 + r * Math.cos(a);
  const y = size / 2 + r * Math.sin(a);
  return (
    <svg className="ring-arc" width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden>
      <circle cx={x} cy={y} r={Math.max(1.6, size / 22)} fill="var(--ring-ideal)" stroke="var(--bg-elev)" strokeWidth={1} />
    </svg>
  );
}

/** 予定の識別バッジ（角丸四角）。カレンダー色の面に白い図形 */
export function EventBadge({ icon, color, size = 32, fallback = 'calendar', label, className = '' }: { icon: string | null | undefined; color: string; size?: number; fallback?: ItemIconId; label?: string; className?: string }) {
  const glyph = Math.round(size * 0.56);
  return (
    <span className={`ident ident-event ${className}`} style={{ width: size, height: size, ['--k' as string]: color, borderRadius: Math.round(size * 0.28) }} {...(label ? { role: 'img', 'aria-label': label } : { 'aria-hidden': true })}>
      <Icon name={resolveItemIcon(icon, fallback).id} size={glyph} strokeWidth={glyphStroke(glyph)} />
    </span>
  );
}
