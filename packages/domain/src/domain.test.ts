import { describe, expect, it } from 'vitest';
import {
  actualProgress, addDays, applyTaskAction, availableActions, canAddSubtask, canScrubProgress, convertKind, delayInfo,
  estimateEnd, findConflicts, HOUR, idealProgress, InvalidTransitionError, layoutDay, makeEvent, makeSubtask, makeTask,
  MINUTE, previewConversion, recordManualProgress, rowTimeLabel, runningAndNext, snapToStep, startOfDay, subtaskProgress,
  suggestFreeSlot, taskBlock, tasksForDay, toggleCheck, toggleSubtask, workedMs,
} from './index';

const day = startOfDay(new Date(2026, 9, 12, 12).getTime());
const at = (h: number, m = 0) => day + h * HOUR + m * MINUTE;

const planned = (h1: number, h2: number) => makeTask({ title: 'レポート', plannedStart: at(h1), plannedEnd: at(h2) }, at(0));

describe('理想進捗', () => {
  it('予定時間から線形に計算し 0..1 に収める', () => {
    const t = planned(10, 12);
    expect(idealProgress(t, at(9))).toBe(0);
    expect(idealProgress(t, at(11))).toBeCloseTo(0.5);
    expect(idealProgress(t, at(13))).toBe(1);
  });
  it('予定時刻がなければ null', () => {
    expect(idealProgress(makeTask({ title: 'x' }, 0), at(10))).toBeNull();
  });
});

describe('状態機械', () => {
  it('開始→一時停止→再開→終了で区間と実績時刻が整合する', () => {
    let t = planned(10, 12);
    t = applyTaskAction(t, 'start', at(10)).task;
    expect(t.status).toBe('running');
    t = applyTaskAction(t, 'pause', at(10, 30)).task;
    expect(t.pausedEver).toBe(true);
    t = applyTaskAction(t, 'resume', at(10, 45)).task;
    const fin = applyTaskAction(t, 'finish', at(11, 15));
    t = fin.task;
    expect(t.status).toBe('done');
    expect(t.actualStart).toBe(at(10));
    expect(t.actualEnd).toBe(at(11, 15));
    expect(workedMs(t, at(20))).toBe(60 * MINUTE);
    expect(fin.log).toMatchObject({ action: 'finish', from: 'running', to: 'done' });
  });

  it('完了の取り消しは一時停止に戻り、取り消しまでの時間を作業時間に加えない', () => {
    let t = applyTaskAction(planned(10, 12), 'start', at(10)).task;
    t = applyTaskAction(t, 'finish', at(11)).task;
    const u = applyTaskAction(t, 'undoFinish', at(11, 30));
    expect(u.task.status).toBe('paused');
    expect(u.task.actualEnd).toBeNull();
    expect(workedMs(u.task, at(12))).toBe(HOUR);
    expect(u.log.action).toBe('undoFinish');
  });

  it('開始の取り消しは未開始に戻し実績を消す（最初の区間のみ）', () => {
    let t = applyTaskAction(planned(10, 12), 'start', at(10)).task;
    expect(availableActions(t)).toContain('undoStart');
    t = applyTaskAction(t, 'undoStart', at(10, 5)).task;
    expect(t.status).toBe('notStarted');
    expect(t.intervals).toEqual([]);
    expect(t.actualStart).toBeNull();
  });

  it('不正な遷移は例外', () => {
    expect(() => applyTaskAction(planned(10, 12), 'finish', at(10))).toThrow(InvalidTransitionError);
    let t = applyTaskAction(planned(10, 12), 'start', at(10)).task;
    t = applyTaskAction(t, 'pause', at(10, 10)).task;
    t = applyTaskAction(t, 'resume', at(10, 20)).task;
    expect(availableActions(t)).not.toContain('undoStart');
  });
});

describe('実績進捗とサブタスク', () => {
  it('サブタスク完了数で等分（3件中1件 ≒ 33.3%）', () => {
    const t = planned(10, 12);
    const subs = [0, 1, 2].map((i) => makeSubtask(t.id, `s${i}`, i, at(0)));
    subs[0] = toggleSubtask(subs[0]!, at(10, 20));
    expect(subtaskProgress(subs)).toBeCloseTo(1 / 3);
    expect(actualProgress(t, subs)).toMatchObject({ source: 'subtasks', sampleAt: at(10, 20) });
  });
  it('サブタスクを持つ親は手動スライド不可', () => {
    const t = planned(10, 12);
    const subs = [makeSubtask(t.id, 'a', 0, 0)];
    expect(canScrubProgress(t, subs)).toBe(false);
    expect(() => recordManualProgress(t, subs, 0.5, at(10))).toThrow();
    expect(canScrubProgress(t, [])).toBe(true);
  });
  it('サブタスクの完了取り消しで完了時刻が消える', () => {
    const s = toggleSubtask(toggleSubtask(makeSubtask('t', 'a', 0, 0), at(1)), at(2));
    expect(s.done).toBe(false);
    expect(s.completedAt).toBeNull();
  });
  it('予定に内包されるタスクはサブタスクを作れない', () => {
    expect(canAddSubtask({ eventId: 'e1', kind: 'do' })).toBe(false);
    expect(canAddSubtask({ eventId: null, kind: 'do' })).toBe(true);
  });
});

describe('ETA（予測終了）', () => {
  it('実績がなければ未算出（値を捏造しない）', () => {
    const t = applyTaskAction(planned(10, 12), 'start', at(10)).task;
    expect(estimateEnd(t, [], at(10, 30))).toEqual({ kind: 'unavailable', reason: 'noBasis' });
  });
  it('手動実績から残り作業時間を推定する', () => {
    let t = applyTaskAction(planned(10, 12), 'start', at(10)).task;
    t = recordManualProgress(t, [], 0.25, at(10, 30)).task; // 30分で25% → 合計120分
    const eta = estimateEnd(t, [], at(10, 40));
    expect(eta).toEqual({ kind: 'estimate', at: at(12) });
  });
  it('作業2分未満・0%・停止中は算出しない', () => {
    let t = applyTaskAction(planned(10, 12), 'start', at(10)).task;
    expect(estimateEnd(recordManualProgress(t, [], 0.1, at(10, 1)).task, [], at(10, 2)).kind).toBe('unavailable');
    expect(estimateEnd(recordManualProgress(t, [], 0, at(10, 30)).task, [], at(10, 31)).kind).toBe('unavailable');
    t = recordManualProgress(t, [], 0.5, at(10, 30)).task;
    t = applyTaskAction(t, 'pause', at(10, 31)).task;
    expect(estimateEnd(t, [], at(10, 40))).toEqual({ kind: 'unavailable', reason: 'notRunning' });
  });
  it('サブタスクの完了時刻の作業量から推定する', () => {
    const t = applyTaskAction(planned(10, 12), 'start', at(10)).task;
    const subs = [makeSubtask(t.id, 'a', 0, 0), makeSubtask(t.id, 'b', 1, 0)];
    subs[0] = toggleSubtask(subs[0]!, at(10, 40)); // 40分で50%
    expect(estimateEnd(t, subs, at(10, 50))).toEqual({ kind: 'estimate', at: at(11, 20) });
  });
});

describe('遅延と行ラベル', () => {
  it('予定終了を過ぎた未完了は遅延', () => {
    const t = applyTaskAction(planned(10, 11), 'start', at(10)).task;
    expect(delayInfo(t, at(11, 5))).toEqual({ delayed: true, overMinutes: 5 });
    expect(delayInfo(t, at(10, 59)).delayed).toBe(false);
  });
  it('遅延ブロックは現在時刻まで描画を延長するが元の予定は変えない', () => {
    const t = applyTaskAction(planned(10, 11), 'start', at(10)).task;
    const b = taskBlock(t, [], at(11, 30))!;
    expect(b.end).toBe(at(11, 30));
    expect(b.plannedEnd).toBe(at(11));
    expect(t.plannedEnd).toBe(at(11));
  });
  it('未開始＝予定開始、実行中＝予定終了/予測、完了＝実績終了', () => {
    let t = planned(10, 12);
    expect(rowTimeLabel(t, [], at(9))).toEqual({ kind: 'plannedStart', at: at(10) });
    t = applyTaskAction(t, 'start', at(10)).task;
    expect(rowTimeLabel(t, [], at(10, 5))).toEqual({ kind: 'plannedEnd', at: at(12) });
    t = applyTaskAction(t, 'finish', at(11)).task;
    expect(rowTimeLabel(t, [], at(11))).toEqual({ kind: 'actualEnd', at: at(11) });
  });
});

describe('日付と並び', () => {
  it('指定日のタスクだけを返す（確認タスクは確認日時）', () => {
    const a = planned(10, 11);
    const b = makeTask({ title: '明日', plannedStart: addDays(at(9), 1), plannedEnd: addDays(at(10), 1) }, 0);
    const c = makeTask({ title: '確認', kind: 'check', checkAt: at(8) }, 0);
    const d = makeTask({ title: '未設定' }, 0);
    expect(tasksForDay([a, b, c, d], day).map((t) => t.title)).toEqual(['確認', 'レポート']);
    expect(tasksForDay([a, b, c, d], addDays(day, 1)).map((t) => t.title)).toEqual(['明日']);
  });
  it('15分刻みにスナップ', () => {
    expect(snapToStep(at(10, 7))).toBe(at(10, 0));
    expect(snapToStep(at(10, 8))).toBe(at(10, 15));
    expect(snapToStep(at(23, 53))).toBe(addDays(day, 1));
  });
  it('実行中と次のタスク', () => {
    const r = applyTaskAction(planned(9, 10), 'start', at(9)).task;
    const n1 = planned(13, 14);
    const n2 = planned(11, 12);
    const res = runningAndNext([r, n1, n2], at(9, 30));
    expect(res.running.map((t) => t.id)).toEqual([r.id]);
    expect(res.next?.id).toBe(n2.id);
    expect(runningAndNext([r], at(9, 30)).next).toBeNull();
  });
});

describe('タイムライン配置・重複', () => {
  it('重なる予定を列に分ける', () => {
    const items = [
      { id: 'a', start: at(9), end: at(11) },
      { id: 'b', start: at(10), end: at(12) },
      { id: 'c', start: at(13), end: at(14) },
    ];
    const placed = layoutDay(items, day);
    const byId = Object.fromEntries(placed.map((p) => [p.item.id, p]));
    expect(byId.a).toMatchObject({ column: 0, columns: 2, top: 540, height: 120 });
    expect(byId.b).toMatchObject({ column: 1, columns: 2 });
    expect(byId.c).toMatchObject({ column: 0, columns: 1 });
  });
  it('日をまたぐ予定は両日に切り分けて描く', () => {
    const night = { id: 'n', start: at(22), end: addDays(at(6), 1) };
    const d1 = layoutDay([night], day)[0]!;
    const d2 = layoutDay([night], addDays(day, 1))[0]!;
    expect(d1).toMatchObject({ top: 22 * 60, height: 120, clippedEnd: true });
    expect(d2).toMatchObject({ top: 0, height: 360, clippedStart: true });
  });
  it('重複を検出し、既存予定を動かさず空き枠を提案する', () => {
    const existing = [makeEvent({ title: '授業', calendarId: 'c', start: at(10), end: at(12) }, 0)];
    const target = { id: 'new', start: at(11), end: at(12) };
    expect(findConflicts(target, existing)).toHaveLength(1);
    expect(suggestFreeSlot(target, existing, day)).toEqual({ start: at(12), end: at(13) });
    expect(existing[0]!.start).toBe(at(10));
  });
});

describe('確認タスク・変換', () => {
  it('チェックで完了、解除で戻る', () => {
    let t = makeTask({ title: '持ち物', kind: 'check', checkAt: at(8) }, 0);
    t = toggleCheck(t, at(8)).task;
    expect(t).toMatchObject({ checked: true, status: 'done', checkedAt: at(8) });
    t = toggleCheck(t, at(9)).task;
    expect(t).toMatchObject({ checked: false, checkedAt: null });
  });
  it('実施→確認で実績履歴を消さない', () => {
    let t = applyTaskAction(planned(10, 12), 'start', at(10)).task;
    expect(previewConversion(t, 'check').warnings.length).toBeGreaterThan(0);
    t = convertKind(t, 'check', at(10, 30)).task;
    expect(t.kind).toBe('check');
    expect(t.intervals).toHaveLength(1);
    expect(t.intervals[0]!.end).toBe(at(10, 30));
    t = convertKind(t, 'do', at(11)).task;
    expect(t.status).toBe('paused');
  });
});
