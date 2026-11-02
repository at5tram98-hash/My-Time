import { useMemo, useRef, useState, type ReactNode } from 'react';
import { motion, useReducedMotion } from 'motion/react';
import { Icon } from '../../components/Icon';
import { Popup } from '../../ui/Popup';
import { SPRING } from '../../ui/motion';

export interface Choice { value: string; label: string; badge?: ReactNode; sub?: string }

/** 行をタップして開く選択シート（C19）。「なし」と候補、多ければ検索。選ぶと閉じて親へ反映 */
export function ChoicePopup({ open, title, items, value, onClose, onPick, noneLabel = 'なし', testId }: { open: boolean; title: string; items: Choice[]; value: string; onClose: () => void; onPick: (v: string) => void; noneLabel?: string; testId?: string }) {
  const [q, setQ] = useState('');
  const shown = useMemo(() => (q.trim() ? items.filter((i) => i.label.includes(q.trim())) : items), [items, q]);
  return (
    <Popup open={open} title={title} onClose={() => { setQ(''); onClose(); }} testId={testId} tall>
      {items.length > 8 && (
        <div className="csearch"><Icon name="search" size={17} className="muted" /><input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder={`${title}を検索`} aria-label={`${title}を検索`} /></div>
      )}
      <div className="group"><div className="group-body" role="radiogroup" aria-label={title}>
        <button type="button" role="radio" aria-checked={value === ''} className={`row row-button sel-row ${value === '' ? 'on' : ''}`} onClick={() => { setQ(''); onPick(''); }}>
          <span className="choice-badge none" aria-hidden />
          <span className="row-label">{noneLabel}</span>
          <span className="sel-mark" aria-hidden>{value === '' && <Icon name="check" size={14} strokeWidth={3} />}</span>
        </button>
        {shown.map((i) => (
          <button key={i.value} type="button" role="radio" aria-checked={value === i.value} className={`row row-button sel-row ${value === i.value ? 'on' : ''}`} onClick={() => { setQ(''); onPick(i.value); }}>
            {i.badge ?? <span className="choice-badge none" aria-hidden />}
            <span className="row-label">{i.label}{i.sub && <span className="sub-label">{i.sub}</span>}</span>
            <span className="sel-mark" aria-hidden>{value === i.value && <Icon name="check" size={14} strokeWidth={3} />}</span>
          </button>
        ))}
        {shown.length === 0 && <div className="row muted">見つかりません</div>}
      </div></div>
    </Popup>
  );
}

const PRIO: { v: 0 | 1 | 2 | 3; label: string; tone: string; mark: string }[] = [
  { v: 0, label: 'なし', tone: 'var(--label-2)', mark: '' },
  { v: 1, label: '低', tone: 'var(--prio-low)', mark: '!' },
  { v: 2, label: '中', tone: 'var(--prio-mid)', mark: '!!' },
  { v: 3, label: '高', tone: 'var(--prio-high)', mark: '!!!' },
];
export const PRIO_TONE = (p: number) => PRIO[p]?.tone ?? 'var(--label-2)';

/** 優先度（C20）：なし＝中立、低＝灰、中＝オレンジ、高＝赤。記号とチェックを併用し、色だけに頼らない */
export function PriorityButtons({ value, onChange }: { value: 0 | 1 | 2 | 3; onChange: (v: 0 | 1 | 2 | 3) => void }) {
  const reduce = useReducedMotion();
  return (
    <div className="prio-btns" role="radiogroup" aria-label="優先度">
      {PRIO.map((p) => {
        const on = value === p.v;
        return (
          <motion.button key={p.v} type="button" role="radio" aria-checked={on} className={`prio-btn ${on ? 'on' : ''}`} style={{ ['--t' as string]: p.tone }} onClick={() => onChange(p.v)}
            animate={reduce ? { scale: 1 } : { scale: on ? 1.03 : 1 }} whileTap={reduce ? undefined : { scale: 0.96 }} transition={SPRING.pop} data-testid={`prio-${p.v}`}>
            {p.mark && <span className="prio-mark-txt" aria-hidden>{p.mark}</span>}
            {p.label}
            {on && <Icon name="check" size={13} strokeWidth={3} />}
          </motion.button>
        );
      })}
    </div>
  );
}

/** 文字列を正規化したタグの配列へ（先頭の # を1つにまとめ、空・重複を除く） */
export function normalizeTags(list: string[]): string[] {
  return [...new Set(list.map((t) => t.replace(/^[#＃]+/, '').trim()).filter(Boolean))].slice(0, 30);
}

/**
 * タグ入力（C21）：確定したタグは角丸のチップ、末尾に未確定の入力欄。
 * Enter・空白・読点・カンマ・フォーカス離脱で確定。日本語の変換中は分割しない。
 * 入力欄が空で Backspace を押すと、直前のチップを選択（もう一度押すと削除）。
 */
export function TagInput({ value, onChange }: { value: string[]; onChange: (v: string[]) => void }) {
  const [draft, setDraft] = useState('');
  const [armed, setArmed] = useState<number | null>(null);
  const composing = useRef(false);
  const commit = (raw: string) => {
    const parts = raw.split(/[\s,、，\u3000]+/);
    const next = normalizeTags([...value, ...parts]);
    if (next.length !== value.length) onChange(next);
    setDraft('');
  };
  return (
    <div className="tag-input" onClick={(e) => (e.currentTarget.querySelector('input') as HTMLInputElement | null)?.focus()} data-testid="tag-input">
      {value.map((t, i) => (
        <span key={t} className={`tag-chip ${armed === i ? 'armed' : ''}`}>
          <span className="tag-chip-text">#{t}</span>
          <button type="button" aria-label={`タグ「${t}」を外す`} onClick={(e) => { e.stopPropagation(); onChange(value.filter((x) => x !== t)); setArmed(null); }}><Icon name="close" size={11} strokeWidth={2.8} /></button>
        </span>
      ))}
      <input
        value={draft}
        onChange={(e) => {
          setArmed(null);
          const v = e.target.value;
          if (!composing.current && /[\s,、，\u3000]$/.test(v)) commit(v);
          else setDraft(v);
        }}
        onCompositionStart={() => { composing.current = true; }}
        onCompositionEnd={(e) => { composing.current = false; setDraft((e.target as HTMLInputElement).value); }}
        onKeyDown={(e) => {
          if (e.nativeEvent.isComposing || composing.current) return;
          if (e.key === 'Enter') { e.preventDefault(); if (draft.trim()) commit(draft); }
          if (e.key === 'Backspace' && !draft && value.length) {
            e.preventDefault();
            if (armed === value.length - 1) { onChange(value.slice(0, -1)); setArmed(null); } else setArmed(value.length - 1);
          }
        }}
        onBlur={() => { if (draft.trim()) commit(draft); setArmed(null); }}
        onPaste={(e) => { const t = e.clipboardData.getData('text'); if (/[\s,、，\u3000]/.test(t)) { e.preventDefault(); commit(draft + t); } }}
        placeholder={value.length ? '' : '#ゼミ #レポート'}
        aria-label="タグを入力（Enter・空白で確定）"
        enterKeyHint="done"
        data-testid="tag-draft"
      />
    </div>
  );
}
