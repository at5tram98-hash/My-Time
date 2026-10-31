import { useMemo, useState } from 'react';
import { addDays, dayStats, formatDuration, isSameDay, startOfDay, wall, weekday, weekdayJa, weekStats } from '@my-time/domain';
import { useData } from '../../app/data';
import { useNow } from '../../app/useNow';
import { Icon } from '../../components/Icon';

function Ring({ value, color, size = 64, stroke = 9, label }: { value: number | null; color: string; size?: number; stroke?: number; label: string }) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  return (
    <svg width={size} height={size} role="img" aria-label={label} className="ring">
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeOpacity={0.2} strokeWidth={stroke} />
      {value != null && value > 0 && (
        <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeDasharray={`${c * Math.min(1, value)} ${c}`} transform={`rotate(-90 ${size / 2} ${size / 2})`} />
      )}
    </svg>
  );
}

const pct = (v: number | null) => (v == null ? '—' : `${Math.round(v * 100)}`);

/**
 * フィットネスの「概要」風タイル。対象は時刻指定された実施タスクのみ（授業・アルバイトの予定は除外）。
 * 一時停止を経験したタスク・自動開始/終了したタスクは、設定で含めるまで集計から除外する。
 */
export function AnalysisScreen() {
  const { tasks, settings } = useData();
  const now = useNow(30_000);
  const [day, setDay] = useState(() => startOfDay(now));
  const opts = { includePaused: settings.analysisIncludePaused, includeAuto: settings.analysisIncludeAuto };
  const ws = addDays(day, -weekday(day));
  const week = useMemo(() => weekStats(tasks, ws, now, opts), [tasks, ws, now, opts.includePaused, opts.includeAuto]); // eslint-disable-line react-hooks/exhaustive-deps
  const today = useMemo(() => dayStats(tasks, day, now, opts), [tasks, day, now, opts.includePaused, opts.includeAuto]); // eslint-disable-line react-hooks/exhaustive-deps
  const maxWork = Math.max(1, ...week.days.map((d) => d.workedMs));
  const label = (t: number) => `${wall(t).mo + 1}月${wall(t).d}日`;

  return (
    <div className="screen analysis" data-testid="analysis-screen">
      <header className="nav large">
        <div className="nav-row"><h1 className="large-title">分析</h1></div>
        <div className="week-nav">
          <button type="button" className="icon-btn" aria-label="前の週" onClick={() => setDay(addDays(day, -7))} data-testid="prev-week"><Icon name="chevronLeft" size={20} /></button>
          <span className="week-label" data-testid="week-label">{label(ws)}〜{label(addDays(ws, 6))}</span>
          <button type="button" className="icon-btn" aria-label="次の週" onClick={() => setDay(addDays(day, 7))} data-testid="next-week"><Icon name="chevronRight" size={20} /></button>
        </div>
        <div className="day-strip" role="tablist" aria-label="日付">
          {week.days.map((d) => (
            <button key={d.day} type="button" role="tab" aria-selected={isSameDay(d.day, day)} className={`day-chip ${isSameDay(d.day, day) ? 'on' : ''} ${isSameDay(d.day, now) ? 'today' : ''}`} onClick={() => setDay(d.day)}>
              <span className="wd">{weekdayJa(d.day)}</span>
              <Ring value={d.completionRate} color="var(--green)" size={30} stroke={4.5} label={`${weekdayJa(d.day)}曜 完了率${pct(d.completionRate)}%`} />
            </button>
          ))}
        </div>
      </header>
      <div className="scroll-body">
        <h2 className="section-title">{isSameDay(day, now) ? '今日' : `${label(day)}（${weekdayJa(day)}）`}</h2>
        <div className="tiles">
          <div className="tile" data-testid="tile-completion">
            <div className="tile-label green">完了率</div>
            <div className="tile-row">
              <Ring value={today.completionRate} color="var(--green)" label={`完了率${pct(today.completionRate)}%`} />
              <div className="tile-value">{pct(today.completionRate)}<small>%</small></div>
            </div>
            <div className="tile-sub">{today.total ? `${today.done} / ${today.total} 件` : '対象のタスクはありません'}</div>
          </div>
          <div className="tile" data-testid="tile-delay">
            <div className="tile-label orange">遅延率</div>
            <div className="tile-row">
              <Ring value={today.delayRate} color="var(--orange)" label={`遅延率${pct(today.delayRate)}%`} />
              <div className="tile-value">{pct(today.delayRate)}<small>%</small></div>
            </div>
            <div className="tile-sub">{today.delayBase ? `${today.delayed} / ${today.delayBase} 件が予定より遅れ` : '判定できるタスクはまだありません'}</div>
          </div>
          <div className="tile wide" data-testid="tile-work">
            <div className="tile-label blue">実行時間</div>
            <div className="tile-value small">{formatDuration(today.workedMs)}</div>
            <div className="tile-sub">開始〜終了の記録から計算</div>
          </div>
        </div>

        <h2 className="section-title">この週</h2>
        <div className="tile wide week-tile" data-testid="week-tile">
          <div className="week-summary">
            <span><b>{pct(week.total.completionRate)}%</b> 完了</span>
            <span><b>{pct(week.total.delayRate)}%</b> 遅延</span>
            <span><b>{formatDuration(week.total.workedMs)}</b></span>
          </div>
          <div className="bars" role="img" aria-label={`この週の実行時間 合計${formatDuration(week.total.workedMs)}`}>
            {week.days.map((d) => (
              <div key={d.day} className={`bar-col ${isSameDay(d.day, day) ? 'on' : ''}`}>
                <div className="bar" style={{ height: `${Math.round((d.workedMs / maxWork) * 100)}%` }} />
                <span className="bar-label">{weekdayJa(d.day)}</span>
              </div>
            ))}
          </div>
        </div>
        <p className="analysis-note">
          授業・アルバイトの予定は集計しません。
          {week.total.excluded > 0 && ` この週は一時停止・自動開始/終了のタスク${week.total.excluded}件を除外しています（「その他」で含められます）。`}
        </p>
      </div>
    </div>
  );
}
