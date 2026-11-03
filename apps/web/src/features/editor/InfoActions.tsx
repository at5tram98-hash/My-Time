import { Icon } from '../../components/Icon';

export function InfoActions({ onMore, onCopy, onEdit }: { onMore: (anchor: HTMLElement) => void; onCopy: () => void; onEdit: () => void }) {
  return <div className="info-actions" role="group" aria-label="予定とタスクの操作">
    <button type="button" className="info-action" aria-label="その他の操作" onClick={(e) => onMore(e.currentTarget)} data-testid="info-more"><Icon name="more" size={22} strokeWidth={1.8} /></button>
    <button type="button" className="info-action" aria-label="別の日にコピー" onClick={onCopy} data-testid="info-copy"><Icon name="copy" size={22} strokeWidth={1.8} /></button>
    <button type="button" className="info-action tint" aria-label="編集" onClick={onEdit} data-testid="info-edit"><Icon name="pencil" size={22} strokeWidth={1.8} /></button>
  </div>;
}

/** A small, read-only time preview; does not mount a second interactive calendar. */
export function InfoTimePreview({ title, start, end, color }: { title: string; start: number; end: number; color: string }) {
  const fmt = (t: number) => new Date(t).toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit' });
  return <div className="info-time-preview" aria-label={`${title} ${fmt(start)}〜${fmt(end)}`}>
    <div className="preview-hours" aria-hidden>{[start - 3600000, start, start + 3600000].map((t) => <span key={t}>{fmt(t)}</span>)}</div>
    <div className="preview-grid"><div className="preview-event" style={{ background: color }}><strong>{title}</strong><span>{fmt(start)}〜{fmt(end)}</span></div></div>
  </div>;
}
