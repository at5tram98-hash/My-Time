import { useMemo } from 'react';
import { formatDuration, formatHm, periodLabel, periodRange, periodStats, workedMs, wall, type AnalysisPeriod, type Task } from '@my-time/domain';
import { useData } from '../../app/data';
import { useUIActions, type AnalysisMetric } from '../../app/ui';
import { useNow } from '../../app/useNow';
import { Sheet } from '../../components/Sheet';
import { Icon } from '../../components/Icon';
import { ComboChart } from './charts';
import { pct, signedDuration } from './AnalysisScreen';

const TITLE: Record<AnalysisMetric, string> = { completion: '完了率', delay: '遅延率', work: '実行時間', planDiff: '予定との差', interruptions: '中断' };
const EXPLAIN: Record<AnalysisMetric, string> = {
  completion: '期間内に予定開始がある「実行」タスクのうち、完了したものの割合です。',
  delay: '予定終了より後に完了した、または未完了のまま予定終了を過ぎたタスクの割合です。判定できるのは完了済みか、予定終了を過ぎたものだけです。',
  work: '開始〜一時停止〜終了の記録から、この期間に実際に作業した時間を合計しています。期間をまたぐ作業は時間で分けて数えます。',
  planDiff: '完了したタスクについて、実行時間から予定時間（予定開始〜予定終了）を引いた合計です。プラスなら予定より長くかかっています。',
  interruptions: '一時停止してから再開した回数の合計です。',
};

/** 分析の詳細（Q49）：指標の説明、推移グラフ、対象タスクの一覧 */
export function AnalysisDetailSheet({ metric, period, from, depth }: { metric: AnalysisMetric; period: AnalysisPeriod; from: number; depth: number }) {
  const { tasks, settings } = useData();
  const { closeSheet, openSheet } = useUIActions();
  const now = useNow(30_000);
  const range = periodRange(period, from);
  const opts = { includePaused: settings.analysisIncludePaused, includeAuto: settings.analysisIncludeAuto };
  const st = useMemo(() => periodStats(tasks, range, now, opts), [tasks, range.from, period, now, opts.includePaused, opts.includeAuto]); // eslint-disable-line react-hooks/exhaustive-deps
  const list = st.taskIds.map((id) => tasks.find((t) => t.id === id)).filter((t): t is Task => !!t);
  const delayedOf = (t: Task) => t.plannedEnd != null && (t.status === 'done' ? (t.actualEnd ?? 0) > t.plannedEnd : now > t.plannedEnd);
  const shown = metric === 'delay' ? list.filter(delayedOf) : metric === 'interruptions' ? list.filter((t) => t.intervals.length > 1) : metric === 'planDiff' ? list.filter((t) => t.status === 'done' && t.plannedEnd != null) : list;
  const big = metric === 'completion' ? `${pct(st.completionRate)}%` : metric === 'delay' ? `${pct(st.delayRate)}%` : metric === 'work' ? formatDuration(st.workedMs) : metric === 'planDiff' ? (st.planDiffCount ? signedDuration(st.planDiffMs) : '—') : `${st.interruptions}回`;
  const points = st.buckets.map((b) => {
    if (metric === 'work') return { label: b.label, bar: b.workedMs, barText: formatDuration(b.workedMs), line: null };
    return { label: b.label, bar: b.total, barText: `${b.total}件`, line: b.completionRate, lineText: b.completionRate == null ? '—' : `${pct(b.completionRate)}%` };
  });
  const side = (t: Task) => {
    if (metric === 'planDiff' && t.plannedStart != null && t.plannedEnd != null) return signedDuration(workedMs(t, now) - (t.plannedEnd - t.plannedStart));
    if (metric === 'interruptions') return `${t.intervals.length - 1}回`;
    if (metric === 'work') return formatDuration(workedMs(t, now));
    return t.status === 'done' ? (delayedOf(t) ? '遅れて完了' : '完了') : delayedOf(t) ? '遅延中' : '未完了';
  };
  const when = (t: Task) => { const a = t.plannedStart ?? t.checkAt; if (a == null) return ''; const w = wall(a); return `${w.mo + 1}/${w.d} ${formatHm(a)}`; };

  return (
    <Sheet onClose={closeSheet} depth={depth} detent="large" title={TITLE[metric]} testId="analysis-detail" left={<button type="button" className="bar-btn" onClick={closeSheet}>閉じる</button>}>
      <div className="detail-big">
        <span className="muted small">{periodLabel(range)}</span>
        <strong data-testid="detail-value">{big}</strong>
      </div>
      <p className="note-text">{EXPLAIN[metric]}</p>
      <div className="tile wide chart-card">
        <ComboChart points={points} barLabel={metric === 'work' ? '実行時間' : '件数'} {...(metric === 'work' ? {} : { lineLabel: '完了率' })} testId="detail-chart" />
      </div>
      <div className="group-header">対象のタスク（{shown.length}件）</div>
      {shown.length === 0 ? <p className="empty-note">該当するタスクはありません。</p> : (
        <div className="group"><div className="group-body" data-testid="detail-list">
          {shown.map((t) => (
            <button key={t.id} type="button" className="row row-button" onClick={() => openSheet({ kind: 'info', entity: 'task', id: t.id })}>
              <Icon name={t.status === 'done' ? 'check' : 'clock'} size={18} className={t.status === 'done' ? 'green' : 'muted'} />
              <span className="row-label">{t.title}<span className="sub-label">{when(t)}</span></span>
              <span className="row-value">{side(t)}</span>
            </button>
          ))}
        </div></div>
      )}
    </Sheet>
  );
}
