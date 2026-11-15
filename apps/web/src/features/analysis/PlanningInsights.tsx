import { useMemo } from 'react';
import {
  addDays, busyItems, deadlineCrowd, expandAll, focusHours, freeTime, lifeAllocation, loadHeatmap, payForecast, remainingLoad, SPEC_GROUPS, startOfDay, weekday, workedMs, yen,
} from '@my-time/domain';
import { Icon } from '../../components/Icon';
import { useData } from '../../app/data';
import { useUIActions } from '../../app/ui';

const hm = (m: number) => `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`;
const md = (t: number) => { const d = new Date(t); return `${d.getMonth() + 1}/${d.getDate()}`; };
const GROUP_LABEL = Object.fromEntries([...SPEC_GROUPS.map((g) => [g.id, g.label]), ['other', 'そのほか']]) as Record<string, string>;
const GROUP_COLOR: Record<string, string> = { work: '#FF9F0A', school: '#5E5CE6', outing: '#0A84FF', life: '#30D158', money: '#34C759', self: '#BF5AF2', other: '#8E8E93' };

/**
 * 振り返りの「計画」まとめ（P31〜P40）。見たい人だけが下までスクロールして見る（普段の画面を増やさない）。
 * 推定は「見込み」と書き、記録が足りないときは値を出さない。
 */
export function PlanningInsights({ now }: { now: number }) {
  const { tasks, events, subtasksByTask, employers, settings, calendarById } = useData();
  const { openSheet } = useUIActions();
  const today = startOfDay(now);
  const opts = { fromHour: settings.suggestFromHour, toHour: settings.suggestToHour, stepMin: settings.suggestStepMin };
  const subs = useMemo(() => [...subtasksByTask.values()].flat(), [subtasksByTask]);
  const evs = useMemo(() => expandAll(events, addDays(today, -40), addDays(today, 40)), [events, today]);
  const busy = useMemo(() => busyItems(evs, tasks, subs), [evs, tasks, subs]);
  const free = useMemo(() => Array.from({ length: 7 }, (_, i) => ({ day: addDays(today, i), ...freeTime(addDays(today, i), busy, opts) })), [today, busy]); // eslint-disable-line react-hooks/exhaustive-deps
  const crowd = useMemo(() => deadlineCrowd(tasks, now, 14), [tasks, now]);
  const monthFrom = new Date(today); monthFrom.setDate(1);
  const monthTo = new Date(monthFrom); monthTo.setMonth(monthTo.getMonth() + 1);
  const pay = useMemo(() => payForecast(evs, employers, monthFrom.getTime(), monthTo.getTime()), [evs, employers, monthFrom.getTime(), monthTo.getTime()]); // eslint-disable-line react-hooks/exhaustive-deps
  const load = useMemo(() => remainingLoad(tasks, busy, now, opts).slice(0, 5), [tasks, busy, now]); // eslint-disable-line react-hooks/exhaustive-deps
  const heat = useMemo(() => loadHeatmap(evs, tasks, subs, today, 14), [evs, tasks, subs, today]);
  const focus = useMemo(() => focusHours(tasks, addDays(today, -28), addDays(today, 1)), [tasks, today]);
  const weekStart = addDays(today, -weekday(today));
  const life = useMemo(() => lifeAllocation(evs, tasks, weekStart, addDays(weekStart, 7), now, (e) => calendarById.get(e.calendarId)?.kind ?? 'general'), [evs, tasks, weekStart, now, calendarById]);
  const accuracy = useMemo(() => {
    const xs = tasks.filter((t) => t.status === 'done' && t.estimateMinutes && t.actualEnd != null).map((t) => workedMs(t, t.actualEnd!) / 60_000 / t.estimateMinutes!).filter((r) => r > 0.05 && r < 10).sort((a, b) => a - b);
    return xs.length >= 3 ? { ratio: xs[Math.floor(xs.length / 2)]!, n: xs.length } : null;
  }, [tasks]);
  const maxHeat = Math.max(60, ...heat.map((h) => h.fixedMinutes + h.taskMinutes));
  const lifeTotal = life.reduce((s, x) => s + x.minutes, 0);

  return (
    <section className="planning" aria-label="計画のふりかえり" data-testid="planning-insights">
      <h2 className="section-title">計画</h2>
      <button type="button" className="tile wide review-tile" onClick={() => openSheet({ kind: 'review', day: today })} data-testid="tile-review">
        <div className="tile-label blue"><Icon name="history" size={14} />今日の振り返り</div>
        <div className="tile-sub">終わったこと・残ったことを確かめ、残りを明日の空きに置く案を出します</div>
        <Icon name="chevronRight" size={16} className="chev" />
      </button>
      <div className="tiles">
        <div className="tile" data-testid="tile-free">
          <div className="tile-label green">今日の余白</div>
          <div className="tile-value">{Math.round((free[0]?.ratio ?? 0) * 100)}<small>%</small></div>
          <div className="tile-sub">{opts.fromHour}〜{opts.toHour}時のうち空き {hm(free[0]?.freeMinutes ?? 0)}（予定・タスク・移動の重なりは1回だけ数えます）</div>
        </div>
        <div className="tile" data-testid="tile-accuracy">
          <div className="tile-label indigo">見積の精度</div>
          {accuracy ? <><div className="tile-value small">×{accuracy.ratio.toFixed(2)}</div><div className="tile-sub">完了{accuracy.n}件の実績 ÷ 見積（中央値）。1より大きいと見積より長くかかっています</div></> : <div className="tile-sub">見積と実績のある完了タスクが3件以上になると表示します</div>}
        </div>
      </div>
      <div className="tile wide" data-testid="tile-week-free">
        <div className="tile-label green">7日間の余白</div>
        <div className="mini-cols">{free.map((f) => <div key={f.day} className="mini-col"><span className="bar" style={{ height: `${Math.round(f.ratio * 100)}%` }} /><span className="lbl">{'日月火水木金土'[new Date(f.day).getDay()]}</span></div>)}</div>
      </div>
      <div className="tile wide" data-testid="tile-deadlines">
        <div className="tile-label orange">期限の集中（14日）</div>
        {crowd.some((c) => c.tasks.length) ? (
          <div className="crowd">
            {crowd.map((c) => <div key={c.day} className={`crowd-cell ${c.tasks.length >= 2 ? 'hot' : c.tasks.length ? 'on' : ''}`} title={c.tasks.map((t) => t.title).join('、')} aria-label={`${md(c.day)} 期限${c.tasks.length}件`}><span>{new Date(c.day).getDate()}</span>{c.tasks.length > 0 && <b>{c.tasks.length}</b>}</div>)}
          </div>
        ) : <div className="tile-sub">14日以内に期限のあるタスクはありません</div>}
        {crowd.filter((c) => c.tasks.length >= 2).slice(0, 2).map((c) => <div key={c.day} className="tile-sub warn">{md(c.day)}に{c.tasks.length}件：{c.tasks.map((t) => t.title).join('、')}。早めに着手する候補です</div>)}
      </div>
      {load.length > 0 && (
        <div className="tile wide" data-testid="tile-load">
          <div className="tile-label pink">課題の残り負荷</div>
          {load.map((l) => (
            <button key={l.task.id} type="button" className="load-row" onClick={() => openSheet({ kind: 'info', entity: 'task', id: l.task.id })}>
              <span className="load-title" data-user-text>{l.task.title}</span>
              <span className={`load-val ${l.remaining > l.free ? 'warn' : ''}`}>残り{hm(l.remaining)} / 空き{hm(l.free)}</span>
              <span className="load-due">期限 {md(l.due)}</span>
            </button>
          ))}
          <div className="tile-sub">残りは見積−実績（見込み）。空きは期限までの{opts.fromHour}〜{opts.toHour}時の空き時間です</div>
        </div>
      )}
      <div className="tile wide" data-testid="tile-heat">
        <div className="tile-label blue">混み具合（14日）</div>
        <div className="mini-cols">
          {heat.map((h) => (
            <div key={h.day} className="mini-col stack" aria-label={`${md(h.day)} 予定${hm(h.fixedMinutes)}・タスク${hm(h.taskMinutes)}`}>
              <span className="bar task" style={{ height: `${(h.taskMinutes / maxHeat) * 100}%` }} />
              <span className="bar fixed" style={{ height: `${(h.fixedMinutes / maxHeat) * 100}%` }} />
              <span className="lbl">{new Date(h.day).getDate()}</span>
            </div>
          ))}
        </div>
        <div className="legend"><span><i className="fixed" />決まった予定</span><span><i className="task" />タスク（見込み）</span></div>
      </div>
      {pay.length > 0 && (
        <div className="tile wide" data-testid="tile-pay">
          <div className="tile-label orange">今月の給与見込み</div>
          {pay.map((p) => (
            <div key={p.workplace} className="pay-row">
              <span className="pay-wp" data-user-text>{p.workplace}</span>
              <span className="pay-val">{yen(p.pay)}<span className="tag-estimate">見込み</span></span>
              <span className="pay-sub">{p.shifts}回・{hm(p.minutes)}{p.transport ? `・交通費${yen(p.transport)}は別` : ''}{p.missingWage ? `・時給未入力${p.missingWage}回を除く` : ''}</span>
            </div>
          ))}
          <div className="tile-sub">税引前。休憩を除いた時間×時給。同じ勤務の二重登録は1回だけ数えます</div>
        </div>
      )}
      {life.length > 0 && (
        <div className="tile wide" data-testid="tile-life">
          <div className="tile-label indigo">今週の時間の使い方</div>
          <div className="life-bar">{life.map((x) => <span key={x.group} style={{ flex: x.minutes, background: GROUP_COLOR[x.group] }} title={GROUP_LABEL[x.group]} />)}</div>
          <div className="legend">{life.map((x) => <span key={x.group}><i style={{ background: GROUP_COLOR[x.group] }} />{GROUP_LABEL[x.group]} {Math.round((x.minutes / lifeTotal) * 100)}%</span>)}</div>
          <div className="tile-sub">予定の長さと、タスクの作業時間を種類ごとに合計。種類を変えると分類も変わります</div>
        </div>
      )}
      <div className="tile wide" data-testid="tile-focus">
        <div className="tile-label green">集中しやすい時間帯</div>
        {focus?.best != null ? <div className="tile-sub">過去4週間に完了した{focus.samples}件では、<b>{focus.best}時台</b>の作業がいちばん多くなっています</div> : <div className="tile-sub">完了したタスクが5件以上になると表示します（傾向がはっきりしないうちは出しません）</div>}
      </div>
    </section>
  );
}
