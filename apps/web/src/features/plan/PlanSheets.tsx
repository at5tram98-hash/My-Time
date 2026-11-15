import { useMemo, useState } from 'react';
import {
  addDays, busyItems, dayReview, deadlineOf, detectIssues, expandAll, formatHm, isUnscheduled, postponeOptions, replanDay, sessionsProposal, startOfDay, tasksForDay,
  type Issue, type Proposal, type Task,
} from '@my-time/domain';
import { Sheet } from '../../components/Sheet';
import { Icon } from '../../components/Icon';
import { TaskBadge } from '../../components/Identity';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';
import { useNow } from '../../app/useNow';
import { TaskRow } from '../tasks/TaskRow';
import { orderHomeTasks } from '../home/homeOrder';
import { PlanPreview } from './PlanPreview';

const md = (t: number) => { const d = new Date(t); return `${d.getMonth() + 1}/${d.getDate()}（${'日月火水木金土'[d.getDay()]}）`; };
const SEV: Record<Issue['severity'], { icon: 'warning' | 'info'; label: string }> = { alert: { icon: 'warning', label: '要対応' }, warn: { icon: 'warning', label: '注意' }, info: { icon: 'info', label: 'お知らせ' } };

function usePlanContext() {
  const { tasks, events, subtasksByTask, settings } = useData();
  const subs = useMemo(() => [...subtasksByTask.values()].flat(), [subtasksByTask]);
  const opts = { fromHour: settings.suggestFromHour, toHour: settings.suggestToHour, stepMin: settings.suggestStepMin };
  return { tasks, events, subs, opts, subtasksByTask };
}

/** 気づいたこと（P06〜P09・P36・P39）：理由と確かさを示し、修正案は差分を見てから適用する */
export function IssuesSheet({ day, depth }: { day: number; depth: number }) {
  const { tasks, events, subs, opts } = usePlanContext();
  const { closeSheet, openSheet } = useUIActions();
  const now = useNow(30_000);
  const evs = useMemo(() => expandAll(events, day - 86_400_000, addDays(day, 3)), [events, day]);
  const issues = useMemo(() => detectIssues({ events: evs, tasks, subtasks: subs, now, from: day, to: addDays(day, 1), opts }), [evs, tasks, subs, now, day]); // eslint-disable-line react-hooks/exhaustive-deps
  const replan = useMemo(() => replanDay(day, evs, tasks, subs, now, undefined, opts), [day, evs, tasks, subs, now]); // eslint-disable-line react-hooks/exhaustive-deps
  const [open, setOpen] = useState<string | null>(null);
  return (
    <Sheet onClose={closeSheet} depth={depth} detent="medium" detents={['medium', 'large']} title="気づいたこと" right={<button type="button" className="bar-btn bold" onClick={closeSheet}>完了</button>} testId="issues-sheet">
      <p className="sheet-lead">予定・タスク・期限・移動を照らし合わせて見つけたことです。時間の決まった予定は自動で動かしません。</p>
      {issues.length === 0 ? (
        <div className="empty-state" data-testid="issues-empty"><Icon name="check" size={28} /><p>気になる点は見つかりませんでした</p></div>
      ) : (
        <div className="issue-list">
          {issues.map((i) => (
            <div key={i.id} className={`issue-card ${i.severity}`} data-testid="issue-card" data-kind={i.kind}>
              <button type="button" className="issue-head" aria-expanded={open === i.id} onClick={() => setOpen(open === i.id ? null : i.id)}>
                <span className={`issue-ico ${i.severity}`} aria-hidden><Icon name={SEV[i.severity].icon} size={16} strokeWidth={2.3} /></span>
                <span className="issue-text">
                  <span className="issue-title">{i.title}</span>
                  <span className="issue-meta">{SEV[i.severity].label}{i.confidence === 'low' ? '・推定（確かではありません）' : ''}{i.proposals.length ? `・修正案${i.proposals.length}件` : ''}</span>
                </span>
                <Icon name="chevronDown" size={16} style={{ transform: open === i.id ? 'rotate(180deg)' : undefined, transition: 'transform 220ms var(--spring)' }} />
              </button>
              {open === i.id && (
                <div className="issue-body">
                  <p className="issue-reason">{i.reason}</p>
                  <div className="issue-refs">
                    {i.refs.map((r) => {
                      const title = r.entity === 'task' ? tasks.find((t) => t.id === r.id)?.title : evs.find((e) => e.id === r.id)?.title;
                      return <button key={`${r.entity}:${r.id}`} type="button" className="gpill glass glass-i" onClick={() => openSheet({ kind: 'info', entity: r.entity, id: r.id })}>{title ?? '項目'}を開く</button>;
                    })}
                  </div>
                  {i.proposals[0] && <PlanPreview proposal={{ ...i.proposals[0], alternatives: i.proposals.slice(1) }} testId="issue-plan" />}
                </div>
              )}
            </div>
          ))}
        </div>
      )}
      <div className="group-header">1日を組み直す</div>
      <div className="group"><div className="group-body padded">
        <PlanPreview proposal={replan} testId="replan-preview" />
      </div></div>
    </Sheet>
  );
}

/** 未割当（P22）：時間を決めていないタスク。1回のタップで空き時間に入れる */
export function InboxSheet({ depth }: { depth: number }) {
  const { tasks, events, subs, opts, subtasksByTask } = usePlanContext();
  const { closeSheet, openSheet } = useUIActions();
  const now = useNow(30_000);
  const list = useMemo(() => tasks
    .filter((t) => t.kind === 'do' && t.status !== 'done' && isUnscheduled(t) && !(subtasksByTask.get(t.id) ?? []).some((s) => s.plannedStart != null && !s.done))
    .map((t) => ({ t, dl: deadlineOf(t) }))
    .sort((a, b) => (a.dl ?? Infinity) - (b.dl ?? Infinity) || b.t.createdAt - a.t.createdAt), [tasks, subtasksByTask]);
  const busy = useMemo(() => busyItems(expandAll(events, now - 86_400_000, now + 30 * 86_400_000), tasks, subs), [events, tasks, subs, now]);
  const [open, setOpen] = useState<string | null>(null);
  return (
    <Sheet onClose={closeSheet} depth={depth} detent="medium" detents={['medium', 'large']} title="未割当" right={<button type="button" className="bar-btn bold" onClick={closeSheet}>完了</button>} testId="inbox-sheet">
      <p className="sheet-lead">いつやるかをまだ決めていないタスクです。期限が近い順に並べています。</p>
      {list.length === 0 ? <div className="empty-state" data-testid="inbox-empty"><Icon name="inbox" size={28} /><p>未割当のタスクはありません</p><button type="button" className="link-btn" onClick={() => openSheet({ kind: 'quickAdd' })}>追加する</button></div> : (
        <div className="issue-list">
          {list.map(({ t, dl }) => {
            const minutes = t.estimateMinutes ?? 30;
            const opts2 = postponeOptions({ ...t, plannedStart: null, plannedEnd: null, estimateMinutes: minutes }, busy, now, opts).filter((o) => !o.id.endsWith(':inbox'));
            const split = minutes > 60 ? sessionsProposal(t, minutes, 60, busy, now, dl, opts) : null;
            const first = opts2[0];
            return (
              <div key={t.id} className="issue-card plain" data-testid="inbox-item">
                <div className="issue-head static">
                  <TaskBadge icon={t.icon} kind="do" size={32} />
                  <button type="button" className="issue-text link" onClick={() => openSheet({ kind: 'info', entity: 'task', id: t.id })}>
                    <span className="issue-title" data-user-text>{t.title}</span>
                    <span className="issue-meta">{dl != null ? `期限 ${md(dl)} ${formatHm(dl)}` : '期限なし'}・{t.estimateMinutes != null ? `見積${t.estimateMinutes}分` : '見積なし（30分で探します）'}</span>
                  </button>
                </div>
                <div className="inbox-actions">
                  {first && <button type="button" className="gpill glass glass-i tint" onClick={() => setOpen(open === `${t.id}:0` ? null : `${t.id}:0`)} data-testid="inbox-place">{first.title}に入れる</button>}
                  {opts2.length > 1 && <button type="button" className="gpill glass glass-i" onClick={() => setOpen(open === `${t.id}:1` ? null : `${t.id}:1`)}>別の時間</button>}
                  {split && <button type="button" className="gpill glass glass-i" onClick={() => setOpen(open === `${t.id}:s` ? null : `${t.id}:s`)} data-testid="inbox-split">分けて置く</button>}
                </div>
                {open === `${t.id}:0` && first && <PlanPreview proposal={first} compact onApplied={() => setOpen(null)} />}
                {open === `${t.id}:1` && opts2[1] && <PlanPreview proposal={{ ...opts2[1], alternatives: opts2.slice(2) }} compact onApplied={() => setOpen(null)} />}
                {open === `${t.id}:s` && split && <PlanPreview proposal={split} compact onApplied={() => setOpen(null)} />}
              </div>
            );
          })}
        </div>
      )}
    </Sheet>
  );
}

/** その日のタスク一覧（長押しで進捗入力・タップで詳細） */
export function DayTasksSheet({ day, depth }: { day: number; depth: number }) {
  const { tasks, subtasksByTask } = useData();
  const { closeSheet, openSheet } = useUIActions();
  const now = useNow();
  const list = useMemo(() => orderHomeTasks(tasksForDay(tasks, day), now), [tasks, day, now]);
  const done = list.filter((t) => t.status === 'done' || t.checked).length;
  return (
    <Sheet onClose={closeSheet} depth={depth} detent="medium" detents={['medium', 'large']} title={startOfDay(now) === day ? '今日のタスク' : `${md(day)}のタスク`} right={<button type="button" className="bar-btn bold" onClick={closeSheet}>完了</button>} testId="day-tasks">
      <div className="list-heading"><span>{list.length ? `${done}/${list.length} 完了` : ''}</span><span className="muted small">長押しで進捗を入力</span></div>
      <div className="task-list" data-testid="home-task-list">
        {list.length === 0 ? (
          <div className="empty-list"><p>時間が指定されたタスクはありません</p><button type="button" className="link-btn" onClick={() => openSheet({ kind: 'quickAdd' })}>タスクを追加</button></div>
        ) : <div className="rows">{list.map((t) => <TaskRow key={t.id} task={t} subtasks={subtasksByTask.get(t.id) ?? []} now={now} />)}</div>}
      </div>
    </Sheet>
  );
}

/** 1日の振り返り（P40）：できたこと・残ったこと・明日の予定と、残りを明日の空きへ置く提案 */
export function ReviewSheet({ day, depth }: { day: number; depth: number }) {
  const { tasks, events, subs, opts } = usePlanContext();
  const { closeSheet, openSheet } = useUIActions();
  const now = useNow(60_000);
  const evs = useMemo(() => expandAll(events, day - 86_400_000, addDays(day, 3)), [events, day]);
  const r = useMemo(() => dayReview(day, evs, tasks, subs, now, opts), [day, evs, tasks, subs, now]); // eslint-disable-line react-hooks/exhaustive-deps
  const row = (t: Task) => <button key={t.id} type="button" className="row row-button" onClick={() => openSheet({ kind: 'info', entity: 'task', id: t.id })}><TaskBadge icon={t.icon} kind="do" size={26} done={t.status === 'done'} /><span className="row-label" data-user-text>{t.title}</span><span className="row-value">{t.plannedStart != null ? formatHm(t.plannedStart) : ''}</span></button>;
  return (
    <Sheet onClose={closeSheet} depth={depth} detent="large" title="1日の振り返り" right={<button type="button" className="bar-btn bold" onClick={closeSheet}>完了</button>} testId="review-sheet">
      <div className="review-stats">
        <div><strong>{r.done.length}</strong><span>完了</span></div>
        <div><strong>{r.unfinished.length}</strong><span>残り</span></div>
        <div><strong>{Math.floor(r.worked / 60)}:{String(r.worked % 60).padStart(2, '0')}</strong><span>作業時間</span></div>
        <div><strong>{Math.round(r.free.ratio * 100)}%</strong><span>明日の余白</span></div>
      </div>
      {r.unfinished.length > 0 && <><div className="group-header">残ったこと</div><div className="group"><div className="group-body">{r.unfinished.map(row)}</div></div></>}
      {r.done.length > 0 && <><div className="group-header">できたこと</div><div className="group"><div className="group-body">{r.done.map(row)}</div></div></>}
      <div className="group-header">明日の予定</div>
      <div className="group"><div className="group-body">
        {r.tomorrowFixed.length ? r.tomorrowFixed.map((e) => <button key={e.id} type="button" className="row row-button" onClick={() => openSheet({ kind: 'info', entity: 'event', id: e.id })}><Icon name="calendar" size={18} className="muted" /><span className="row-label" data-user-text>{e.title}</span><span className="row-value">{e.extra?.allDay ? '終日' : `${formatHm(e.start)}〜${formatHm(e.end)}`}</span></button>) : <div className="row"><span className="row-label muted">予定はありません</span></div>}
      </div></div>
      {r.proposal && <><div className="group-header">提案</div><div className="group"><div className="group-body padded"><PlanPreview proposal={r.proposal} testId="review-plan" /></div></div></>}
    </Sheet>
  );
}

/** 延期・分割（P29・P30）。期限は変えない */
export function RescheduleSheet({ taskId, mode, depth }: { taskId: string; mode: 'postpone' | 'split'; depth: number }) {
  const { tasks, events, subs, opts } = usePlanContext();
  const { closeSheet } = useUIActions();
  const now = useNow(30_000);
  const t = tasks.find((x) => x.id === taskId);
  const [total, setTotal] = useState<number>(() => t?.estimateMinutes ?? (t?.plannedStart != null && t.plannedEnd != null ? Math.round((t.plannedEnd - t.plannedStart) / 60_000) : 60));
  const [per, setPer] = useState(60);
  const busy = useMemo(() => busyItems(expandAll(events, now - 86_400_000, now + 30 * 86_400_000), tasks, subs), [events, tasks, subs, now]);
  if (!t) return <Sheet onClose={closeSheet} depth={depth} detent="small" title="タスク"><p className="empty-note">このタスクは削除されました。</p></Sheet>;
  const proposals: Proposal[] = mode === 'postpone' ? postponeOptions(t, busy, now, opts) : [];
  const split = mode === 'split' ? sessionsProposal(t, Math.max(15, total), Math.max(15, per), busy.filter((b) => b.refId !== t.id), now, deadlineOf(t), opts) : null;
  return (
    <Sheet onClose={closeSheet} depth={depth} detent="medium" detents={['medium', 'large']} title={mode === 'postpone' ? '延期する' : '分けて進める'} right={<button type="button" className="bar-btn bold" onClick={closeSheet}>閉じる</button>} testId="reschedule-sheet">
      <p className="sheet-lead" data-user-text>「{t.title}」{mode === 'postpone' ? 'を別の時間へ移します。期限は変わりません。' : 'を何回かの作業枠に分け、空き時間に置きます。'}</p>
      {mode === 'postpone' && proposals[0] && <div className="group"><div className="group-body padded"><PlanPreview proposal={{ ...proposals[0], alternatives: proposals.slice(1) }} onApplied={closeSheet} testId="postpone-preview" /></div></div>}
      {mode === 'split' && (
        <>
          <div className="group"><div className="group-body">
            <div className="row"><span className="row-label">全体の時間</span><span className="row-value"><input className="num-input" type="number" min={15} step={15} value={total} onChange={(e) => setTotal(Number(e.target.value) || 0)} aria-label="全体の時間（分）" data-testid="split-total" />分</span></div>
            <div className="row"><span className="row-label">1回の長さ</span><span className="row-value seg-mini" role="radiogroup" aria-label="1回の長さ">{[30, 45, 60, 90].map((m) => <button key={m} type="button" role="radio" aria-checked={per === m} className={per === m ? 'on' : ''} onClick={() => setPer(m)}>{m}分</button>)}</span></div>
          </div></div>
          {split ? <div className="group"><div className="group-body padded"><PlanPreview proposal={split} onApplied={closeSheet} testId="split-preview" /></div></div> : <p className="muted small center">置ける空き時間が見つかりませんでした。</p>}
        </>
      )}
    </Sheet>
  );
}
