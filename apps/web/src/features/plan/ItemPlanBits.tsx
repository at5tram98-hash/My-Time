import { useMemo, useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { busyItems, expandAll, shiftProposal, type ExternalSource } from '@my-time/domain';
import { Icon } from '../../components/Icon';
import { useData, useSync } from '../../app/data';
import { db } from '../../data/db';
import { PlanPreview } from './PlanPreview';

/**
 * 時間を少しずらす（P23：ドラッグの代わりのボタン操作）。押すと変更前→変更後と影響を見せ、「この内容で変更」で保存する。
 * つながっている準備タスクも一緒に動かす。
 */
export function NudgeBar({ entity, id, title, start, end }: { entity: 'task' | 'event'; id: string; title: string; start: number; end: number }) {
  const { tasks, events, subtasksByTask } = useData();
  const [delta, setDelta] = useState<number | null>(null);
  const busy = useMemo(() => (delta == null ? [] : busyItems(expandAll(events, start - 86_400_000, end + 86_400_000), tasks, [...subtasksByTask.values()].flat())), [delta, events, tasks, subtasksByTask, start, end]);
  const p = delta == null ? null : shiftProposal(entity, { id, title, start, end }, delta, tasks, busy);
  return (
    <div className="nudge" data-testid="nudge-bar">
      <div className="nudge-row" role="group" aria-label="時間をずらす">
        <span className="nudge-label"><Icon name="clock" size={14} />時間をずらす</span>
        {[-60, -15, 15, 60].map((m) => (
          <button key={m} type="button" className={`nudge-btn ${delta === m ? 'on' : ''}`} aria-pressed={delta === m} onClick={() => setDelta(delta === m ? null : m)} data-testid={`nudge-${m}`}>
            {m > 0 ? '+' : '−'}{Math.abs(m) >= 60 ? `${Math.abs(m) / 60}時間` : `${Math.abs(m)}分`}
          </button>
        ))}
      </div>
      {p && <PlanPreview proposal={p} compact onApplied={() => setDelta(null)} testId="nudge-preview" />}
    </div>
  );
}

const ORIGIN: Record<string, string> = { manual: '手入力', text: '文章から追加', import: '取り込み', plan: '提案から作成' };
const SOURCE: Record<string, string> = { timetree: 'TimeTree', ics: 'カレンダーファイル（ICS）', text: '貼り付けたテキスト' };

/** 出所・最終更新・送信待ち（P18・P19） */
export function OriginRows({ entity, id, origin, source, updatedAt }: { entity: 'task' | 'event'; id: string; origin: string | null; source: ExternalSource | null; updatedAt: number }) {
  const pending = useLiveQuery(() => db.outbox.where('synced').equals(0).filter((o) => o.entity === entity && o.entityId === id).count(), [entity, id]) ?? 0;
  const sync = useSync();
  const label = source ? `${SOURCE[source.type] ?? source.type}から取り込み${source.owner === 'partner' ? '（相手の予定）' : ''}` : ORIGIN[origin ?? ''] ?? '手入力';
  return (
    <div className="group" data-testid="origin-rows">
      <div className="group-header">記録</div>
      <div className="group-body">
        <div className="row"><Icon name="info" size={18} className="muted" /><span className="row-label">入力元</span><span className="row-value" data-testid="origin-label">{label}</span></div>
        <div className="row"><Icon name="history" size={18} className="muted" /><span className="row-label">最終更新</span><span className="row-value">{new Date(updatedAt).toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' })}</span></div>
        {sync.me && <div className="row"><Icon name="cloud" size={18} className="muted" /><span className="row-label">同期</span><span className="row-value" data-testid="origin-sync">{pending ? `送信待ち（${pending}件の変更）` : sync.lastSuccessAt ? `同期済み・${new Date(sync.lastSuccessAt).toLocaleTimeString('ja-JP', { hour: '2-digit', minute: '2-digit' })}` : '未同期'}</span></div>}
      </div>
    </div>
  );
}
