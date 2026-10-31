import { useMemo } from 'react';
import { formatDuration, startOfDay, tasksForDay, workedMs } from '@my-time/domain';
import { useData } from '../../app/data';
import { useNow } from '../../app/useNow';

/**
 * Phase 1 は「今日」の簡易集計のみ（実データから計算）。
 * 遅延率・週集計・除外設定など本格的な分析は Phase 2 で実装する。
 */
export function AnalysisScreen() {
  const { tasks } = useData();
  const now = useNow(30_000);
  const today = useMemo(() => tasksForDay(tasks, startOfDay(now)).filter((t) => t.kind === 'do'), [tasks, now]);
  const done = today.filter((t) => t.status === 'done').length;
  const worked = today.reduce((s, t) => s + workedMs(t, now), 0);
  const rate = today.length ? Math.round((done / today.length) * 100) : null;

  return (
    <div className="screen analysis" data-testid="analysis-screen">
      <header className="nav large">
        <div className="nav-row"><h1 className="large-title">分析</h1></div>
      </header>
      <div className="scroll-body">
        <div className="tiles">
          <div className="tile">
            <div className="tile-label green">今日の完了</div>
            <div className="tile-value">{rate == null ? '—' : <>{rate}<small>%</small></>}</div>
            <div className="tile-sub">{today.length ? `${done} / ${today.length} 件` : '今日の実施タスクはありません'}</div>
          </div>
          <div className="tile">
            <div className="tile-label blue">今日の作業時間</div>
            <div className="tile-value small">{formatDuration(worked)}</div>
            <div className="tile-sub">開始〜終了の実績から計算</div>
          </div>
        </div>
        <div className="placeholder-card">
          <h2>準備中</h2>
          <p>遅延率、週ごとの集計と日付移動、集計対象の設定（一時停止・自動開始/終了の除外）は Phase 2 で追加します。授業・アルバイトの予定は集計の対象外です。</p>
        </div>
      </div>
    </div>
  );
}
