import { useId, useState } from 'react';
import { Sheet } from '../../components/Sheet';
import { Toggle } from '../../components/Controls';
import { useData } from '../../app/data';
import { useUI } from '../../app/ui';
import { fromLocalInput, toLocalInput } from '../../app/format';
import { repo } from '../../data/repo';

/**
 * AR（自動開始・自動終了の予約）。開始・終了ボタンの長押しで開く。
 * 予約時刻に作業した記録として反映される（アプリを閉じていても、次に開いたとき正しい時刻で反映）。
 * 分析では初期設定で集計対象外。
 */
export function AutoReserveSheet({ taskId, depth }: { taskId: string; depth: number }) {
  const { tasks } = useData();
  const { closeSheet, showToast } = useUI();
  const fid = useId();
  const task = tasks.find((t) => t.id === taskId);
  const [startOn, setStartOn] = useState(task?.autoStartAt != null || task?.status === 'notStarted');
  const [endOn, setEndOn] = useState(task?.autoEndAt != null || task?.status !== 'notStarted');
  const [start, setStart] = useState(toLocalInput(task?.autoStartAt ?? task?.plannedStart ?? Date.now()));
  const [end, setEnd] = useState(toLocalInput(task?.autoEndAt ?? task?.plannedEnd ?? Date.now() + 3_600_000));
  const [error, setError] = useState<string | null>(null);
  if (!task) return null;

  const save = async () => {
    const s = startOn && task.status === 'notStarted' ? fromLocalInput(start) : null;
    const e = endOn ? fromLocalInput(end) : null;
    if (s != null && e != null && e <= s) return setError('終了は開始より後にしてください');
    await repo.setAutoReservation(task.id, { autoStartAt: s, autoEndAt: e });
    await repo.applyAutoReservations();
    showToast(s != null || e != null ? '自動開始・終了を予約しました' : '予約を解除しました');
    closeSheet();
  };

  return (
    <Sheet
      onClose={closeSheet}
      depth={depth}
      title="自動開始・終了の予約"
      left={<button type="button" className="bar-btn" onClick={closeSheet}>キャンセル</button>}
      right={<button type="button" className="bar-btn bold" onClick={() => void save()} data-testid="save-ar">保存</button>}
    >
      <p className="sheet-lead">「{task.title}」を指定した時刻に自動で開始・終了します。一覧には <span className="ar-badge">AR</span> が付き、分析では初期設定で集計に含めません。</p>
      <div className="group">
        <div className="group-body">
          {task.status === 'notStarted' && (
            <>
              <div className="row">
                <label className="row-label" htmlFor={`${fid}-so`}>自動で開始</label>
                <Toggle id={`${fid}-so`} label="自動で開始" checked={startOn} onChange={setStartOn} />
              </div>
              {startOn && (
                <div className="row">
                  <label className="row-label" htmlFor={`${fid}-s`}>開始時刻</label>
                  <input id={`${fid}-s`} type="datetime-local" className="dt-input" value={start} onChange={(e) => setStart(e.target.value)} data-testid="ar-start" />
                </div>
              )}
            </>
          )}
          <div className="row">
            <label className="row-label" htmlFor={`${fid}-eo`}>自動で終了</label>
            <Toggle id={`${fid}-eo`} label="自動で終了" checked={endOn} onChange={setEndOn} />
          </div>
          {endOn && (
            <div className="row">
              <label className="row-label" htmlFor={`${fid}-e`}>終了時刻</label>
              <input id={`${fid}-e`} type="datetime-local" className="dt-input" value={end} onChange={(e) => setEnd(e.target.value)} data-testid="ar-end" />
            </div>
          )}
        </div>
      </div>
      {error && <p className="form-error" role="alert">{error}</p>}
    </Sheet>
  );
}
