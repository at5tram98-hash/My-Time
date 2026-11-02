import { useMemo, useState } from 'react';
import { defaultCalendarIcon, expandEvent, newId, formatHm, parseOccurrenceId, resolveItemIcon } from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Icon } from '../../components/Icon';
import { EventBadge } from '../../components/Identity';
import { Toggle } from '../../components/Controls';
import { useData, useSync } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { repo } from '../../data/repo';
import { InfoExtras } from '../tasks/TaskDetailSheet';
import { StudioValueView } from '../studio/StudioFieldsForm';
import { describeRule, notifySummary } from './pickers';
import { MapPreview, travelLabel } from './place';
import { useTimelineActions } from '../timeline/useTimelineActions';
import { syncEngine } from '../../sync/engine';

const fmtDay = (t: number) => { const d = new Date(t); return `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日（${'日月火水木金土'[d.getDay()]}）`; };

/** 予定の情報確認（Q62）：約半分の高さ。大きなアイコン・タイトル・日時、繰り返し・通知は小アイコン、右上に編集 */
export function EventInfoSheet({ id, depth }: { id: string; depth: number }) {
  const { events, calendarById, employers, studioTypes } = useData();
  const { closeSheet, openSheet } = useUIActions();
  const actions = useTimelineActions();
  const occ = parseOccurrenceId(id);
  const master = events.find((e) => e.id === (occ?.masterId ?? id));
  const inst = useMemo(() => (master && occ ? expandEvent(master, occ.originalStart - 8 * 86_400_000, occ.originalStart + 8 * 86_400_000).find((o) => o.id === id) : master), [master, id]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!master || !inst) {
    return <Sheet onClose={closeSheet} depth={depth} detent="small" title="予定"><p className="empty-note">この予定は削除されました。</p></Sheet>;
  }
  const cal = calendarById.get(master.calendarId);
  const color = master.extra?.color ?? cal?.color ?? '#0A84FF';
  const st = cal?.studioTypeId ? studioTypes.find((t) => t.id === cal.studioTypeId) : undefined;
  const allDay = master.extra?.allDay;
  return (
    <Sheet
      onClose={closeSheet}
      depth={depth}
      detent="medium"
      detents={['medium', 'large']}
      testId="event-info"
      left={<button type="button" className="bar-btn" onClick={closeSheet}>閉じる</button>}
      right={<button type="button" className="gbtn glass glass-i tint" aria-label="編集" onClick={() => openSheet({ kind: 'edit', mode: 'event', id })} data-testid="info-edit"><Icon name="pencil" size={18} /></button>}
    >
      <div className="info-hero">
        <EventBadge icon={st ? st.icon : cal?.icon} color={color} size={56} fallback={defaultCalendarIcon(cal?.kind ?? 'general')} />
        <div className="info-head">
          <h2 className="detail-title" data-testid="info-title">{inst.title}</h2>
          <div className="info-when">{fmtDay(inst.start)}{allDay ? ' 終日' : ` ${formatHm(inst.start)}〜${formatHm(inst.end)}`}</div>
          <div className="info-badges">
            {master.recurrence && <span className="badge-mini"><Icon name="undo" size={13} />{describeRule(master.recurrence)}</span>}
            {(master.extra?.notifies ?? []).length > 0 && <span className="badge-mini" data-testid="info-notify"><Icon name="bell" size={13} />{notifySummary(master.extra!.notifies!)}</span>}
            {cal && <span className="badge-mini"><span className="dot" style={{ background: cal.color }} />{cal.name}</span>}
          </div>
        </div>
      </div>
      {master.classInfo && (
        <div className="group"><div className="group-body">
          <div className="row"><Icon name="graduation" size={18} className="muted" /><span className="row-label">科目</span><span className="row-value">{master.classInfo.subjectName}</span></div>
          {master.classInfo.room && <div className="row"><Icon name="house" size={18} className="muted" /><span className="row-label">教室</span><span className="row-value">{master.classInfo.room}</span></div>}
          {master.classInfo.assignments.length > 0 && <div className="row"><Icon name="note" size={18} className="muted" /><span className="row-label">課題</span><span className="row-value">{master.classInfo.assignments.length}件</span></div>}
        </div></div>
      )}
      {master.employerId && <div className="group"><div className="group-body"><div className="row"><Icon name="briefcase" size={18} className="muted" /><span className="row-label">勤務先</span><span className="row-value">{employers.find((e) => e.id === master.employerId)?.name ?? '—'}</span></div></div></div>}
      {st && master.extra?.studio && (
        <div className="group"><div className="group-header">{st.name}</div><div className="group-body">
          {st.fields.filter((f) => f.showInInfo && !f.hidden && f.type !== 'note').map((f) => <div className="row" key={f.id}><span className="row-label">{f.label}</span><span className="row-value"><StudioValueView f={f} value={master.extra!.studio!.values[f.id]} /></span></div>)}
        </div></div>
      )}
      {master.extra?.place && (
        <>
          <div className="group-header">場所</div>
          <MapPreview place={master.extra.place} />
          {master.extra.travelMinutes ? <p className="muted small info-travel">{travelLabel(master.extra.travelMinutes)}（出発の目安 {formatHm(inst.start - master.extra.travelMinutes * 60_000)}）</p> : null}
        </>
      )}
      <InfoExtras extra={master.extra} />
      {inst.notes && <div className="group"><div className="group-header">メモ</div><div className="group-body padded notes">{inst.notes}</div></div>}
      <div className="group"><div className="group-body">
        <button type="button" className="row row-button center" onClick={() => openSheet({ kind: 'copyEvent', eventId: id })}>別の日にコピー</button>
        <button type="button" className="row row-button destructive center" onClick={() => { closeSheet(); actions.onEventMenu(id); }} data-testid="info-more">その他の操作…</button>
      </div></div>
    </Sheet>
  );
}

/** カレンダーの表示・非表示（Q31）。管理・作成は「その他」へ */
const CAL_COLORS = ['#0A84FF', '#5E5CE6', '#BF5AF2', '#FF375F', '#FF453A', '#FF9F0A', '#FFD60A', '#30D158', '#64D2FF', '#8E8E93'];

export function CalendarFilterSheet({ depth }: { depth: number }) {
  const { calendars } = useData();
  const { closeSheet, showToast } = useUIActions();
  // カレンダー選択からそのまま追加できる（v3.1）。名前と色だけ決め、細かい設定は「その他」の「カレンダー」で
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState('');
  const [color, setColor] = useState(CAL_COLORS[calendars.length % CAL_COLORS.length]!);
  const add = async () => {
    const n = name.trim();
    if (!n) return showToast('名前を入力してください');
    const now = Date.now();
    try {
      await repo.saveCalendar({ id: newId(), name: n, color, icon: 'calendar', kind: 'general', studioTypeId: null, visible: true, order: calendars.length, createdAt: now, updatedAt: now }, true);
      setAdding(false); setName('');
      showToast(`「${n}」を追加しました`);
    } catch (e) { showToast(e instanceof Error ? e.message : '追加できませんでした'); }
  };
  return (
    <Sheet onClose={closeSheet} depth={depth} detent="small" title="表示するカレンダー" right={<button type="button" className="bar-btn bold" onClick={closeSheet}>完了</button>} testId="calendar-filter">
      <div className="group"><div className="group-body">
        {calendars.map((c) => (
          <div className="row" key={c.id}>
            <span className="cal-chip small" style={{ background: c.color }} aria-hidden><Icon name={resolveItemIcon(c.icon, defaultCalendarIcon(c.kind)).id} size={14} /></span>
            <span className="row-label">{c.name}</span>
            <Toggle label={`${c.name}を表示`} checked={c.visible} onChange={(b) => void repo.saveCalendar({ ...c, visible: b }, false)} />
          </div>
        ))}
        {!adding ? (
          <button type="button" className="row row-button add-row" onClick={() => setAdding(true)} data-testid="filter-add-calendar">
            <span className="cal-chip small add" aria-hidden><Icon name="plus" size={14} strokeWidth={2.6} /></span>
            <span className="row-label tint-text">カレンダーを追加</span>
          </button>
        ) : (
          <div className="row add-cal-form" data-testid="filter-add-form">
            <div className="add-cal-top">
              <span className="cal-chip small" style={{ background: color }} aria-hidden><Icon name="calendar" size={14} /></span>
              <input className="row-input" autoFocus value={name} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && !e.nativeEvent.isComposing) void add(); }} placeholder="カレンダー名" aria-label="カレンダー名" enterKeyHint="done" data-testid="filter-add-name" />
            </div>
            <div className="add-cal-colors" role="radiogroup" aria-label="色">
              {CAL_COLORS.map((c) => <button key={c} type="button" role="radio" aria-checked={c === color} aria-label={c} className={`color-dot ${c === color ? 'on' : ''}`} style={{ background: c }} onClick={() => setColor(c)} />)}
            </div>
            <div className="add-cal-actions">
              <button type="button" className="gpill glass glass-i" onClick={() => { setAdding(false); setName(''); }}>キャンセル</button>
              <button type="button" className="gpill glass glass-i tint" disabled={!name.trim()} onClick={() => void add()} data-testid="filter-add-save">追加</button>
            </div>
          </div>
        )}
      </div><div className="group-footer">種類や並び順の変更は「その他」の「カレンダー」で行えます。</div></div>
    </Sheet>
  );
}

/** 同期の詳細（Q57）：最終同期・未送信件数・再試行 */
export function SyncStatusSheet({ depth }: { depth: number }) {
  const sync = useSync();
  const { outboxPending } = useData();
  const { closeSheet } = useUIActions();
  const last = sync.lastSuccessAt;
  return (
    <Sheet onClose={closeSheet} depth={depth} detent="small" title="同期" right={<button type="button" className="bar-btn bold" onClick={closeSheet}>完了</button>} testId="sync-sheet">
      <div className="group"><div className="group-body">
        <div className="row"><span className="row-label">アカウント</span><span className="row-value">{sync.me?.user.email ?? 'ログインしていません'}</span></div>
        <div className="row"><span className="row-label">状態</span><span className="row-value" data-testid="sync-phase">{({ idle: '同期済み', synced: '同期済み', syncing: '同期中', offline: 'オフライン', error: 'エラー', notConfigured: 'サーバー未設定', unavailable: '利用できません', loggedOut: 'ログインしていません', starting: '準備中' } as Record<string, string>)[sync.phase] ?? sync.phase}</span></div>
        <div className="row"><span className="row-label">最終同期</span><span className="row-value">{last ? new Date(last).toLocaleString('ja-JP') : '—'}</span></div>
        <div className="row"><span className="row-label">未送信の変更</span><span className="row-value" data-testid="sync-pending">{outboxPending}件</span></div>
        {sync.lastError && <div className="row"><span className="row-label">エラー</span><span className="row-value small">{sync.lastError}</span></div>}
      </div></div>
      {sync.me && <button type="button" className="gbtn-primary big glass-i" onClick={() => void syncEngine.syncNow()} data-testid="sync-retry">今すぐ同期</button>}
      <p className="note-text">端末への保存は即時です。クラウドへの反映は通信できるときに行います。</p>
    </Sheet>
  );
}
