import { useMemo, useRef, useState } from 'react';
import { formatDuration, MINUTE, periodLabel, periodRange, periodStats, shiftPeriod, startOfDay, type AnalysisPeriod, type PeriodRange, type PeriodStats } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUIActions, type AnalysisMetric } from '../../app/ui';
import { useNow } from '../../app/useNow';
import { Icon } from '../../components/Icon';
import { repo } from '../../data/repo';
import { Popup } from '../../ui/Popup';
import { ComboChart, MiniBars } from './charts';

const PERIODS: [AnalysisPeriod, string][] = [['day', '日'], ['week', '週'], ['month', '月'], ['year', '年']];
const PREV_LABEL: Record<AnalysisPeriod, string> = { day: '前日', week: '前の週', month: '前の月', year: '前の年' };
const WD = ['日', '月', '火', '水', '木', '金', '土'];

export const pct = (v: number | null) => (v == null ? '—' : `${Math.round(v * 100)}`);
export const signedDuration = (ms: number) => `${ms > 0 ? '+' : ms < 0 ? '−' : '±'}${formatDuration(Math.abs(ms))}`;

/** 期間の長さに合わせた実行時間の目標（週の目標から換算） */
export function workGoalMs(weeklyMin: number | null, r: PeriodRange): number | null {
  if (!weeklyMin) return null;
  return (weeklyMin * MINUTE * (r.to - r.from)) / (7 * 86_400_000);
}

function Ring({ value, color, size = 58, stroke = 8, label }: { value: number | null; color: string; size?: number; stroke?: number; label: string }) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  return (
    <svg width={size} height={size} role="img" aria-label={label} className="stat-ring">
      <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeOpacity={0.2} strokeWidth={stroke} />
      {value != null && value > 0 && <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeDasharray={`${c * Math.min(1, value)} ${c}`} transform={`rotate(-90 ${size / 2} ${size / 2})`} />}
      {value != null && value > 1 && <circle cx={size / 2} cy={size / 2} r={r} fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeDasharray={`${c * Math.min(1, value - 1)} ${c}`} transform={`rotate(-90 ${size / 2} ${size / 2})`} style={{ filter: 'brightness(0.8)' }} />}
    </svg>
  );
}

/** 前の期間との差。良くなったか悪くなったかは指標の向きで判定（遅延・中断は少ないほど良い） */
function Delta({ now, prev, kind, lowerIsBetter }: { now: number | null; prev: number | null; kind: 'pct' | 'time' | 'count'; lowerIsBetter?: boolean }) {
  if (now == null || prev == null) return <span className="delta muted">比較なし</span>;
  const d = now - prev;
  if (Math.abs(d) < (kind === 'pct' ? 0.005 : kind === 'time' ? MINUTE : 0.5)) return <span className="delta muted">変化なし</span>;
  const good = lowerIsBetter ? d < 0 : d > 0;
  const text = kind === 'pct' ? `${d > 0 ? '+' : '−'}${Math.round(Math.abs(d) * 100)}ポイント` : kind === 'time' ? signedDuration(d) : `${d > 0 ? '+' : '−'}${Math.abs(d)}回`;
  return <span className={`delta ${good ? 'good' : 'bad'}`}><span aria-hidden>{d > 0 ? '↑' : '↓'}</span>{text}</span>;
}

/**
 * 分析（Q42〜51）：日・週・月・年を切り替え、左右スワイプで期間を移動。前の期間と比較し、
 * 目標は設定したときだけリングで表示。対象は時刻指定された実施タスク（予定・授業は含まない）。
 */
export function AnalysisScreen() {
  const { tasks, settings } = useData();
  const { openSheet } = useUIActions();
  const now = useNow(30_000);
  const [period, setPeriod] = useState<AnalysisPeriod>('day');
  const [anchor, setAnchor] = useState(() => startOfDay(now));
  const [goals, setGoals] = useState(false);
  const range = periodRange(period, anchor);
  const prevRange = shiftPeriod(range, -1);
  const opts = { includePaused: settings.analysisIncludePaused, includeAuto: settings.analysisIncludeAuto };
  const st = useMemo(() => periodStats(tasks, range, now, opts), [tasks, range.from, range.period, now, opts.includePaused, opts.includeAuto]); // eslint-disable-line react-hooks/exhaustive-deps
  const pv = useMemo(() => periodStats(tasks, prevRange, now, opts), [tasks, prevRange.from, prevRange.period, now, opts.includePaused, opts.includeAuto]); // eslint-disable-line react-hooks/exhaustive-deps
  const isCurrent = now >= range.from && now < range.to;
  const goalMs = workGoalMs(settings.goalWeeklyMinutes, range);
  const goalRate = settings.goalCompletionRate != null ? settings.goalCompletionRate / 100 : null;
  const empty = st.total === 0 && st.workedMs === 0;
  const swipe = useRef<{ x: number; y: number } | null>(null);
  const go = (n: number) => setAnchor(shiftPeriod(range, n).from);
  const detail = (metric: AnalysisMetric) => openSheet({ kind: 'analysisDetail', metric, period, from: range.from });

  return (
    <div className="screen analysis" data-testid="analysis-screen">
      <header className="nav large">
        <div className="nav-row">
          <h1 className="large-title">分析</h1>
          <button type="button" className="gbtn glass glass-i tint" aria-label="目標" onClick={() => setGoals(true)} data-testid="analysis-goals"><Icon name="target" size={20} /></button>
        </div>
        <div className="seg-full" role="tablist" aria-label="期間">
          {PERIODS.map(([p, l]) => <button key={p} type="button" role="tab" aria-selected={period === p} onClick={() => setPeriod(p)} data-testid={`period-${p}`}>{l}</button>)}
        </div>
        <div className="week-nav">
          <button type="button" className="icon-btn" aria-label={PREV_LABEL[period]} onClick={() => go(-1)} data-testid="prev-period"><Icon name="chevronLeft" size={20} /></button>
          <button type="button" className="week-label plain" onClick={() => setAnchor(startOfDay(now))} aria-label={`${periodLabel(range)}（タップで今日に戻る）`} data-testid="period-label">{periodLabel(range)}</button>
          <button type="button" className="icon-btn" aria-label="次の期間" onClick={() => go(1)} data-testid="next-period"><Icon name="chevronRight" size={20} /></button>
        </div>
      </header>
      <div
        className="scroll-body"
        onPointerDown={(e) => { if (!(e.target as Element).closest('svg, button')) swipe.current = { x: e.clientX, y: e.clientY }; }}
        onPointerUp={(e) => {
          const s = swipe.current; swipe.current = null;
          if (s && Math.abs(e.clientX - s.x) > 70 && Math.abs(e.clientY - s.y) < 40) go(e.clientX < s.x ? 1 : -1);
        }}
      >
        {empty ? (
          <div className="empty-state" data-testid="analysis-empty">
            <Icon name="chart" size={40} />
            <strong>この期間の記録はまだありません</strong>
            <span>時刻を決めた「実行」タスクを開始・完了すると、ここに集計されます。</span>
          </div>
        ) : (
          <>
            <div className="tiles">
              <button type="button" className="tile" onClick={() => detail('completion')} data-testid="tile-completion">
                <div className="tile-label green">完了率</div>
                <div className="tile-row">
                  <Ring value={goalRate ? (st.completionRate ?? 0) / goalRate : st.completionRate} color="var(--green)" label={`完了率${pct(st.completionRate)}%${goalRate ? `、目標${Math.round(goalRate * 100)}%` : ''}`} />
                  <div className="tile-value">{pct(st.completionRate)}<small>%</small></div>
                </div>
                <div className="tile-sub">{st.total ? `${st.done} / ${st.total} 件` : '対象のタスクはありません'}{goalRate ? ` · 目標${Math.round(goalRate * 100)}%` : ''}</div>
                <Delta now={st.completionRate} prev={pv.completionRate} kind="pct" />
              </button>
              <button type="button" className="tile" onClick={() => detail('delay')} data-testid="tile-delay">
                <div className="tile-label orange">遅延率</div>
                <div className="tile-row">
                  <Ring value={st.delayRate} color="var(--orange)" label={`遅延率${pct(st.delayRate)}%`} />
                  <div className="tile-value">{pct(st.delayRate)}<small>%</small></div>
                </div>
                <div className="tile-sub">{st.delayBase ? `${st.delayed} / ${st.delayBase} 件が予定より遅れ` : '判定できるタスクはまだありません'}</div>
                <Delta now={st.delayRate} prev={pv.delayRate} kind="pct" lowerIsBetter />
              </button>
              <button type="button" className="tile wide" onClick={() => detail('work')} data-testid="tile-work">
                <div className="tile-label blue">実行時間</div>
                <div className="tile-row">
                  {goalMs && <Ring value={st.workedMs / goalMs} color="var(--blue)" label={`目標の${Math.round((st.workedMs / goalMs) * 100)}%`} />}
                  <div>
                    <div className="tile-value small">{formatDuration(st.workedMs)}</div>
                    <div className="tile-sub">{goalMs ? `目標 ${formatDuration(goalMs)}（${Math.round((st.workedMs / goalMs) * 100)}%）` : '開始〜終了の記録から計算'}</div>
                  </div>
                </div>
                <Delta now={st.workedMs} prev={pv.workedMs} kind="time" />
              </button>
              <button type="button" className="tile" onClick={() => detail('planDiff')} data-testid="tile-plan-diff">
                <div className="tile-label indigo">予定との差</div>
                <div className="tile-value small">{st.planDiffCount ? signedDuration(st.planDiffMs) : '—'}</div>
                <div className="tile-sub">{st.planDiffCount ? `完了${st.planDiffCount}件の実行時間 − 予定時間` : '完了したタスクがありません'}</div>
              </button>
              <button type="button" className="tile" onClick={() => detail('interruptions')} data-testid="tile-interruptions">
                <div className="tile-label pink">中断</div>
                <div className="tile-value small">{st.interruptions}<small>回</small></div>
                <div className="tile-sub">一時停止してから再開した回数</div>
                <Delta now={st.interruptions} prev={pv.interruptions} kind="count" lowerIsBetter />
              </button>
            </div>

            <h2 className="section-title">推移</h2>
            <div className="tile wide chart-card">
              <ComboChart testId="analysis-chart" barLabel="実行時間" lineLabel="完了率" points={st.buckets.map((b) => ({ label: b.label, bar: b.workedMs, barText: formatDuration(b.workedMs), line: b.completionRate, lineText: b.completionRate == null ? '—' : `${pct(b.completionRate)}%` }))} highlight={isCurrent ? st.buckets.findIndex((b, i) => now >= b.from && (st.buckets[i + 1]?.from ?? range.to) > now) : undefined} />
            </div>

            {st.workedMs > 0 && (
              <>
                <h2 className="section-title">よく取り組む曜日と時間帯</h2>
                <div className="tile wide">
                  {period !== 'day' && <MiniBars title="曜日別の実行時間" testId="by-weekday" values={st.byWeekday} labels={WD} />}
                  <MiniBars title="時間帯別の実行時間" testId="by-hour" values={[0, 3, 6, 9, 12, 15, 18, 21].map((h) => st.byHour.slice(h, h + 3).reduce((a, b) => a + b, 0))} labels={['0時', '3', '6', '9', '12', '15', '18', '21']} />
                </div>
              </>
            )}
          </>
        )}
        <p className="analysis-note">
          {PREV_LABEL[period]}と比べています。授業・アルバイトなどの予定は集計しません。複数日にまたがるタスクは予定開始の日に1回だけ数え、実行時間は実際に作業した時間帯に振り分けます。
          {st.excluded > 0 && ` この期間は一時停止・自動開始/終了のタスク${st.excluded}件を除外しています（「その他」で含められます）。`}
        </p>
      </div>
      <GoalsPopup open={goals} onClose={() => setGoals(false)} />
    </div>
  );
}

function GoalsPopup({ open, onClose }: { open: boolean; onClose: () => void }) {
  const { settings } = useData();
  const [w, setW] = useState<string>('');
  const [r, setR] = useState<string>('');
  const [init, setInit] = useState(false);
  if (open && !init) { setW(settings.goalWeeklyMinutes ? String(Math.round(settings.goalWeeklyMinutes / 60 * 10) / 10) : ''); setR(settings.goalCompletionRate != null ? String(settings.goalCompletionRate) : ''); setInit(true); }
  if (!open && init) setInit(false);
  const save = () => {
    const h = Number(w);
    const p = Number(r);
    void repo.updateSettings({ goalWeeklyMinutes: w && h > 0 ? Math.round(h * 60) : null, goalCompletionRate: r && p > 0 ? Math.min(100, Math.round(p)) : null });
    onClose();
  };
  return (
    <Popup open={open} title="目標" onClose={onClose} onDone={save} testId="goals-popup">
      <p className="note-text">目標は任意です。空欄にすると目標リングを表示しません。日・月・年は週の目標から換算します。</p>
      <div className="group"><div className="group-body">
        <div className="row"><span className="row-label">1週間の実行時間</span><span className="dur-inputs"><input type="number" inputMode="decimal" min={0} value={w} onChange={(e) => setW(e.target.value)} aria-label="1週間の実行時間（時間）" placeholder="なし" data-testid="goal-weekly" />時間</span></div>
        <div className="row"><span className="row-label">完了率</span><span className="dur-inputs"><input type="number" inputMode="numeric" min={0} max={100} value={r} onChange={(e) => setR(e.target.value)} aria-label="完了率の目標（%）" placeholder="なし" data-testid="goal-rate" />%</span></div>
      </div></div>
    </Popup>
  );
}

export type { PeriodStats };
