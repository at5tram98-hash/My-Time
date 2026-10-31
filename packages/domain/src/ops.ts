import type { CalEvent, Employer, EpochMs, Task } from './types';
import { applyTaskAction, type TaskTransition } from './taskMachine';
import { formatHm, HOUR, MINUTE, startOfDay } from './time';
import { needsSetup } from './special';

/** 指数バックオフ＋ジッター（同期の自動再試行）。attempt=0 が初回の再試行 */
export function retryDelay(attempt: number, rand: number = Math.random(), baseMs = 2_000, capMs = 10 * 60_000): number {
  const exp = Math.min(capMs, baseMs * 2 ** Math.max(0, attempt));
  return Math.round(exp / 2 + (exp / 2) * Math.min(1, Math.max(0, rand)));
}

/**
 * AR（自動開始・自動終了予約）を時刻どおりに反映する。
 * アプリを閉じていても、次に開いたときに「予約時刻に実行した」記録として正しい時刻で反映される。
 */
export function applyAutoReservation(task: Task, now: EpochMs): TaskTransition[] {
  const out: TaskTransition[] = [];
  let t = task;
  if (t.kind !== 'do') return out;
  if (t.autoStartAt != null && t.autoStartAt <= now && t.status === 'notStarted') {
    const tr = applyTaskAction(t, 'start', t.autoStartAt);
    t = { ...tr.task, autoReserved: true, autoStartAt: null };
    out.push({ task: t, log: { ...tr.log, detail: { auto: true } } });
  }
  if (t.autoEndAt != null && t.autoEndAt <= now && (t.status === 'running' || t.status === 'paused')) {
    const at = Math.max(t.autoEndAt, t.intervals.at(-1)?.start ?? t.autoEndAt);
    const tr = applyTaskAction(t, 'finish', at);
    t = { ...tr.task, autoReserved: true, autoEndAt: null };
    out.push({ task: t, log: { ...tr.log, detail: { auto: true } } });
  }
  return out;
}

export interface PlannedNotice {
  /** 同じ通知を二度送らないための安定キー */
  key: string;
  at: EpochMs;
  title: string;
  body: string;
  /** タップしたときに開く対象 */
  target: { kind: 'task' | 'event' | 'settings'; id: string | null };
}

export const NOT_STARTED_BODY = 'タスク未開始。タスクを修正するか、今すぐ開始してください。';

/**
 * (now - windowMs, now] の間に送るべき通知を列挙する（サーバーCronとアプリ表示中の両方で使う）。
 * - 実施タスク：予定開始から5分過ぎても未開始なら「未開始」通知（AR予約中は送らない）
 * - タスク・確認タスク：指定した分数前のリマインダー
 * - アルバイト：勤務開始の◯時間前（初期2時間）「【勤務先】◯時間前」
 * - 未設定タスク：1日1回だけまとめて入力を促す（20時）
 * - 授業・アルバイトなど通常の予定には「未開始」通知を送らない
 */
export function planNotices(tasks: readonly Task[], events: readonly CalEvent[], employers: readonly Employer[], now: EpochMs, windowMs: number): PlannedNotice[] {
  const inWin = (at: EpochMs) => at <= now && at > now - windowMs;
  const out: PlannedNotice[] = [];
  for (const t of tasks) {
    if (t.kind === 'do' && t.plannedStart != null && t.status === 'notStarted' && t.autoStartAt == null) {
      const at = t.plannedStart + 5 * MINUTE;
      if (inWin(at)) out.push({ key: `notstarted:${t.id}:${t.plannedStart}`, at, title: t.title, body: NOT_STARTED_BODY, target: { kind: 'task', id: t.id } });
    }
    const anchor = t.kind === 'check' ? t.checkAt : t.plannedStart;
    if (t.notifyMinutesBefore != null && anchor != null && t.status !== 'done') {
      const at = anchor - t.notifyMinutesBefore * MINUTE;
      if (inWin(at)) out.push({ key: `remind:${t.id}:${anchor}:${t.notifyMinutesBefore}`, at, title: t.title, body: t.notifyMinutesBefore === 0 ? '時間になりました' : `${t.notifyMinutesBefore}分後に${t.kind === 'check' ? '確認' : '開始'}します`, target: { kind: 'task', id: t.id } });
    }
  }
  const empById = new Map(employers.map((e) => [e.id, e]));
  for (const e of events) {
    if (!e.employerId) continue;
    const emp = empById.get(e.employerId);
    if (!emp) continue;
    const at = e.start - emp.reminderHours * HOUR;
    if (inWin(at)) out.push({ key: `job:${e.id}:${e.start}`, at, title: `【${emp.name}】${emp.reminderHours}時間前`, body: `${formatHm(e.start)} から勤務です`, target: { kind: 'event', id: e.id } });
  }
  const setup = tasks.filter((t) => t.status !== 'done' && (t.special === 'assignment' || t.special === 'testPrep') && needsSetup(t));
  if (setup.length) {
    const at = startOfDay(now) + 20 * HOUR;
    if (inWin(at)) out.push({ key: `setup:${startOfDay(now)}`, at, title: '未設定のタスク', body: `作業時間が未入力の課題・テスト対策が${setup.length}件あります`, target: { kind: 'settings', id: null } });
  }
  return out;
}
