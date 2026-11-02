import type { StudioField, StudioProgressMode, StudioType } from './types';

/**
 * Create Studio の単位・換算・進捗（Q85・Q86）。
 * 単位は「ID（換算に使う）・次元・表示名」を分ける。換算できない異なる単位どうしは数値を変えない。
 */
export interface UnitDef { id: string; label: string; dim: 'time' | 'count' | 'page' | 'money' | 'custom'; toBase: number }
export const UNITS: UnitDef[] = [
  { id: 'min', label: '分', dim: 'time', toBase: 1 },
  { id: 'hour', label: '時間', dim: 'time', toBase: 60 },
  { id: 'times', label: '回', dim: 'count', toBase: 1 },
  { id: 'piece', label: '個', dim: 'count', toBase: 1 },
  { id: 'page', label: 'ページ', dim: 'page', toBase: 1 },
  { id: 'yen', label: '円', dim: 'money', toBase: 1 },
];

export function unitOf(id: string | null | undefined): UnitDef | null {
  if (!id) return null;
  if (id.startsWith('custom:')) return { id, label: id.slice(7).slice(0, 20), dim: 'custom', toBase: 1 };
  return UNITS.find((u) => u.id === id) ?? null;
}
export const unitLabel = (id: string | null | undefined) => unitOf(id)?.label ?? '';

/** 換算：同じ次元（時間どうし等）なら変換し、それ以外は null（値は自動で変えない） */
export function convertUnit(value: number, from: string, to: string): number | null {
  const a = unitOf(from);
  const b = unitOf(to);
  if (!a || !b) return null;
  if (a.id === b.id) return value;
  if (a.dim !== b.dim || a.dim === 'custom' || a.dim === 'count') return null;
  return (value * a.toBase) / b.toBase;
}

/** 数値の表示（単位つき）。小数の桁は項目の設定に従う */
export function formatValue(f: Pick<StudioField, 'unit' | 'precision'>, v: number): string {
  const p = f.precision ?? 0;
  const s = Number.isFinite(v) ? v.toFixed(p).replace(/\.0+$/, p ? '' : '') : '—';
  const u = unitLabel(f.unit);
  return u === '円' ? `${Number(s).toLocaleString('ja-JP')}円` : `${s}${u}`;
}

/**
 * 進捗（Q86）。分母0・目標超過・負値を安全に扱う（0〜1に収め、超過は over=true）。
 * - number：現在値/目標値  - checklist：チェック済み/項目数  - time：実行時間(分)/目標(分)  - manual：0〜100の入力
 */
export function studioProgress(type: Pick<StudioType, 'progress' | 'fields'>, values: Record<string, unknown>, workedMinutes = 0): { value: number | null; over: boolean; label: string } {
  const { mode, fieldId, target } = type.progress as { mode: StudioProgressMode; fieldId: string | null; target: number | null };
  const clamp = (x: number) => Math.max(0, Math.min(1, x));
  if (mode === 'none') return { value: null, over: false, label: '' };
  if (mode === 'checklist') {
    const checks = type.fields.filter((f) => f.type === 'check' && !f.hidden);
    if (!checks.length) return { value: null, over: false, label: '項目なし' };
    const done = checks.filter((f) => values[f.id] === true).length;
    return { value: done / checks.length, over: false, label: `${done}/${checks.length}項目` };
  }
  if (mode === 'manual') {
    const raw = Number(values[fieldId ?? ''] ?? 0);
    const v = Number.isFinite(raw) ? raw : 0;
    return { value: clamp(v / 100), over: v > 100, label: `${Math.round(Math.max(0, v))}%` };
  }
  const f = type.fields.find((x) => x.id === fieldId);
  const cur = mode === 'time' ? workedMinutes : Number(values[fieldId ?? ''] ?? 0);
  const t = target ?? 0;
  const c = Number.isFinite(cur) ? Math.max(0, cur) : 0;
  if (!(t > 0)) return { value: null, over: false, label: f ? formatValue(f, c) : `${c}` };
  const unit = mode === 'time' ? '分' : unitLabel(f?.unit);
  return { value: clamp(c / t), over: c > t, label: `${+c.toFixed(f?.precision ?? 0)}/${t}${unit}` };
}

/** 項目の部品ライブラリ（検索できる説明つき：Q102。Q84 で承認された種類だけ） */
export const STUDIO_PARTS: { type: StudioField['type']; label: string; desc: string; words: string[] }[] = [
  { type: 'text', label: '1行テキスト', desc: '教室名・科目名など短い文字', words: ['テキスト', '文字', '名前', '教室'] },
  { type: 'multiline', label: '複数行テキスト', desc: '内容・感想など長い文章', words: ['メモ', '文章', '内容'] },
  { type: 'number', label: '数値', desc: 'ページ数・金額・回数（単位つき）', words: ['数', '数値', 'ページ', '金額', '円', '回', '時給'] },
  { type: 'datetime', label: '日時', desc: '締切・試験日など', words: ['日付', '期限', '締切', '日時'] },
  { type: 'duration', label: '時間量', desc: '休憩時間・目標時間など（分・時間）', words: ['時間', '休憩', '長さ', '分'] },
  { type: 'toggle', label: 'オン／オフ', desc: '持ち物あり・提出済みなど', words: ['スイッチ', 'オン', 'オフ', 'はい'] },
  { type: 'check', label: 'チェック項目', desc: '手順・持ち物のチェック（進捗に使える）', words: ['チェック', 'やること', '手順'] },
  { type: 'select', label: '選択（1つ）', desc: '難易度・場所の区分など', words: ['選択', '区分', 'カテゴリ'] },
  { type: 'multiselect', label: '選択（複数）', desc: '使う教材・メンバーなど', words: ['複数', '選択', 'タグ'] },
  { type: 'url', label: 'URL', desc: '資料や提出先のリンク', words: ['リンク', 'URL', 'ウェブ'] },
  { type: 'place', label: '場所', desc: '教室・勤務先の住所など', words: ['場所', '住所', '地図'] },
  { type: 'file', label: '画像・PDF', desc: '写真・資料を添付（Googleドライブ）', words: ['画像', '写真', 'PDF', '添付', 'ファイル'] },
  { type: 'progress', label: '進捗（手動％）', desc: '0〜100% を自分で入力', words: ['進捗', 'パーセント', '達成'] },
  { type: 'worktime', label: '実行時間', desc: '開始〜完了で記録した時間を表示', words: ['実行時間', '作業時間', '経過'] },
  { type: 'note', label: '説明・区切り', desc: '入力欄の説明文や見出し', words: ['説明', '見出し', '区切り'] },
];

export function searchParts(q: string) {
  const k = q.trim().toLowerCase();
  if (!k) return STUDIO_PARTS;
  return STUDIO_PARTS.filter((p) => p.label.toLowerCase().includes(k) || p.desc.toLowerCase().includes(k) || p.words.some((w) => w.toLowerCase().includes(k) || k.includes(w.toLowerCase())));
}

/** 利用中の種類を変更・削除するときの影響（Q91）：値が入っている記録の数と、型が変わる項目 */
export function studioImpact(prev: Pick<StudioType, 'fields'>, next: Pick<StudioType, 'fields'>, records: { values: Record<string, unknown> }[]) {
  const removed = prev.fields.filter((f) => !f.hidden && !next.fields.some((n) => n.id === f.id && !n.hidden));
  const retyped = prev.fields.filter((f) => next.fields.some((n) => n.id === f.id && n.type !== f.type));
  const affected = records.filter((r) => [...removed, ...retyped].some((f) => r.values[f.id] != null && r.values[f.id] !== '')).length;
  return { removed, retyped, affected };
}

/** 進捗の根拠（D3・F2・R1）。全画面（リング・説明・実績欄・進捗パネル）で同じ結果を使う */
export type ResolvedProgressSource = 'done' | 'studio' | 'subtasks' | 'manual' | 'none';
export interface ResolvedProgress {
  /** 0〜1。根拠がないときは null（0%へすり替えない） */
  value: number | null;
  source: ResolvedProgressSource;
  /** 表示用の短い値（例：20/100ページ、2/3件、45%） */
  label: string;
  /** 根拠の説明 */
  basis: string;
  /** 未完了のサブタスク件数（親が完了でも残件を見せる：R1） */
  openSubtasks: number;
  totalSubtasks: number;
  /** Studio 数値進捗のとき、クイック入力で更新する項目（C26） */
  studioField?: StudioField;
  studioTarget?: number | null;
  over?: boolean;
}

/**
 * 進捗の根拠を1つに決める。優先順：完了 → Studio の進捗方式 → サブタスク → 手動 → 未入力。
 * 理想進捗は別の指標なので、ここには含めない。
 */
export function resolveProgress(
  task: { status: string; manualProgress: { value: number } | null; extra?: { studio?: { typeId: string; values: Record<string, unknown> } | null } | null },
  subtasks: readonly { done: boolean }[],
  studioType: Pick<StudioType, 'progress' | 'fields'> | null | undefined,
  workedMinutes = 0,
): ResolvedProgress {
  const total = subtasks.length;
  const open = subtasks.filter((s) => !s.done).length;
  const base = { openSubtasks: open, totalSubtasks: total };
  if (task.status === 'done') return { ...base, value: 1, source: 'done', label: '100%', basis: open ? `完了済み（未完了のサブタスク${open}件）` : '完了済み' };
  if (studioType && studioType.progress.mode !== 'none' && task.extra?.studio) {
    const sp = studioProgress(studioType, task.extra.studio.values ?? {}, workedMinutes);
    const f = studioType.fields.find((x) => x.id === studioType.progress.fieldId);
    const modeJa = { number: '入力した数値', time: '実行時間', checklist: 'チェック項目', manual: '手動の進捗' } as Record<string, string>;
    return { ...base, value: sp.value, source: 'studio', label: sp.value == null ? sp.label || '未入力' : sp.label, basis: `専用の項目（${modeJa[studioType.progress.mode] ?? '進捗'}）から計算`, ...(f ? { studioField: f } : {}), studioTarget: studioType.progress.target, over: sp.over };
  }
  if (total) return { ...base, value: (total - open) / total, source: 'subtasks', label: `${total - open}/${total}件`, basis: 'サブタスクの完了数から計算' };
  if (task.manualProgress) return { ...base, value: task.manualProgress.value, source: 'manual', label: `${Math.round(task.manualProgress.value * 100)}%`, basis: '手動で入力した実績' };
  return { ...base, value: null, source: 'none', label: '未入力', basis: '実績はまだ入力されていません' };
}
