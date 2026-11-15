import { useState } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { toICS, type CalEvent } from '@my-time/domain';
import { Group } from '../../components/Controls';
import { Icon } from '../../components/Icon';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { db } from '../../data/db';
import { repo } from '../../data/repo';

const ACTION: Record<string, string> = {
  create: '作成', update: '編集', delete: '削除', move: '時間を移動', plan: '提案を適用', 'plan-undo': '提案を取り消し', 'plan-create': '作業枠を追加', rollback: '元に戻した',
  start: '開始', pause: '一時停止', resume: '再開', finish: '完了', undoFinish: '完了を取り消し', progress: '進捗を入力', check: 'チェック', spec: '種類の詳細を変更', copy: 'コピー', repeat: '繰り返しの次の回', 'undo-create': '追加を取り消し',
};
const ENTITY: Record<string, string> = { task: 'タスク', event: '予定', subtask: 'サブタスク', calendar: 'カレンダー', employer: '勤務先', category: 'カテゴリー', subject: '科目', studioType: 'Studio' };
const titleOf = (d: Record<string, unknown> | undefined) => ((d?.snapshot as { title?: string } | undefined)?.title ?? '');
const when = (t: number) => new Date(t).toLocaleString('ja-JP', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });

/**
 * 変更履歴（P48）：誰が（手入力・提案・文章から・同期）何を変えたかを新しい順に。
 * 変更前の内容を記録した操作（編集・移動・削除）は「この前の状態に戻す」で戻せる。
 */
export function HistoryPage() {
  const { confirm, showToast } = useUIActions();
  const [limit, setLimit] = useState(60);
  const logs = useLiveQuery(() => db.operationLog.orderBy('seq').reverse().limit(limit).toArray(), [limit]) ?? [];
  const back = async (seq: number, label: string) => {
    if (!(await confirm({ title: '元に戻しますか？', message: `「${label}」をこの操作の前の内容に戻します。戻したことも履歴に残ります。`, confirmLabel: '元に戻す' }))) return;
    try { const t = await repo.rollback(seq); showToast(`「${t}」を戻しました`); } catch (e) { showToast(e instanceof Error ? e.message : '戻せませんでした'); }
  };
  return (
    <>
      <Group footer="この端末での操作の記録です。変更前の内容を記録した操作（編集・時間の移動・削除）だけ戻せます。">
        {logs.length === 0 && <div className="row"><span className="row-label muted">まだ記録はありません</span></div>}
        {logs.map((l) => {
          const label = titleOf(l.detail) || ENTITY[l.entity] || l.entity;
          const by = l.detail?.origin === 'text' ? '文章から' : l.detail?.proposal ? '提案' : l.action === 'migrate' ? '移行' : '';
          const canBack = !!l.detail?.snapshot && (l.entity === 'task' || l.entity === 'event');
          return (
            <div key={l.seq} className="row history-row" data-testid="history-row">
              <span className="row-label">
                <span data-user-text>{label}</span>
                <span className="sub-label">{when(l.at)}・{ENTITY[l.entity] ?? l.entity}を{ACTION[l.action] ?? l.action}{by ? `（${by}）` : ''}</span>
              </span>
              {canBack && <button type="button" className="gpill glass glass-i" onClick={() => void back(l.seq!, label)} data-testid="history-rollback"><Icon name="undo" size={14} />戻す</button>}
            </div>
          );
        })}
        {logs.length >= limit && <button type="button" className="row row-button center tint-text" onClick={() => setLimit(limit + 100)}>さらに表示</button>}
      </Group>
    </>
  );
}

/**
 * 同期で守った変更（P17）：サーバー側の新しい版や削除と重なったため、この端末の内容を上書きせずに残したもの。
 * 内容を見て、必要なものだけ「この内容で戻す」を選ぶ（自動では戻さない）。
 */
export function RecoveryPage() {
  const rows = useLiveQuery(() => db.recovery.orderBy('at').reverse().limit(100).toArray(), []) ?? [];
  const { confirm, showToast } = useUIActions();
  const restore = async (key: string) => {
    const r = await db.recovery.get(key);
    if (!r) return;
    const title = String((r.record as { title?: string }).title ?? '');
    if (!(await confirm({ title: 'この内容で戻しますか？', message: `「${title}」を、同期のときに守ったこの端末の内容に戻します。いまの内容は変更履歴から戻せます。`, confirmLabel: 'この内容で戻す' }))) return;
    try {
      if (r.entity === 'task') await repo.saveTask(r.record as never, false);
      else if (r.entity === 'event') await repo.saveEvent(r.record as never, false);
      else throw new Error('この種類は戻せません');
      showToast('戻しました');
    } catch (e) { showToast(e instanceof Error ? e.message : '戻せませんでした'); }
  };
  const reason = (s: string) => (s.startsWith('tombstone') ? 'ほかの端末・期限処理で削除されていた' : s === 'conflict' ? 'ほかの端末の変更と重なった' : s);
  return (
    <Group footer="勝手に上書きせず、ここに残しています。内容を確かめて、必要なものだけ戻してください。">
      {rows.length === 0 && <div className="row"><span className="row-label muted">守った変更はありません</span></div>}
      {rows.map((r) => (
        <div key={r.key} className="row history-row" data-testid="recovery-row">
          <span className="row-label"><span data-user-text>{String((r.record as { title?: string }).title ?? r.id)}</span><span className="sub-label">{when(r.at)}・{ENTITY[r.entity] ?? r.entity}・{reason(r.reason)}</span></span>
          {(r.entity === 'task' || r.entity === 'event') && <button type="button" className="gpill glass glass-i" onClick={() => void restore(r.key)}>この内容で戻す</button>}
        </div>
      ))}
    </Group>
  );
}

/** 予定を書き出す（P15：iCalendar）。ほかのカレンダーアプリで読み込める */
export function ExportPage() {
  const { events, calendars } = useData();
  const { showToast } = useUIActions();
  const [cal, setCal] = useState<string>('all');
  const pick: CalEvent[] = events.filter((e) => cal === 'all' || e.calendarId === cal);
  const download = () => {
    const ics = toICS(pick, cal === 'all' ? 'My Time' : calendars.find((c) => c.id === cal)?.name ?? 'My Time');
    const url = URL.createObjectURL(new Blob([ics], { type: 'text/calendar;charset=utf-8' }));
    const a = document.createElement('a');
    a.href = url; a.download = `my-time-${new Date().toISOString().slice(0, 10)}.ics`;
    document.body.appendChild(a); a.click(); a.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 2000);
    showToast(`${pick.length}件を書き出しました`);
  };
  return (
    <>
      <Group footer="繰り返し・取り消した回・その回だけの変更を含めて、標準のカレンダー形式（.ics）で保存します。時刻は世界標準時で書き、元のタイムゾーンも記録します。">
        <div className="row"><span className="row-label">カレンダー</span>
          <select className="select-input" value={cal} onChange={(e) => setCal(e.target.value)} aria-label="書き出すカレンダー" data-testid="export-calendar"><option value="all">すべて</option>{calendars.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select>
        </div>
        <div className="row"><span className="row-label">予定</span><span className="row-value">{pick.length}件</span></div>
        <button type="button" className="row row-button center tint-text" disabled={!pick.length} onClick={download} data-testid="export-ics"><Icon name="copy" size={16} />.ics で書き出す</button>
      </Group>
    </>
  );
}
