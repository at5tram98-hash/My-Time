/** 絶対時刻はすべて UTC epoch ミリ秒。表示用のタイムゾーンは別フィールドで保持する。 */
export type EpochMs = number;
export type Id = string;

export type CalendarKind = 'general' | 'class' | 'job';

export interface Calendar {
  id: Id;
  name: string;
  color: string;
  kind: CalendarKind;
  visible: boolean;
  order: number;
  createdAt: EpochMs;
  updatedAt: EpochMs;
}

export interface CalEvent {
  id: Id;
  title: string;
  calendarId: Id;
  start: EpochMs;
  end: EpochMs;
  timeZone: string;
  notes: string;
  createdAt: EpochMs;
  updatedAt: EpochMs;
}

export type TaskKind = 'do' | 'check';
export type TaskStatus = 'notStarted' | 'running' | 'paused' | 'done';

/** 実際に作業した区間。end=null は計測中。 */
export interface WorkInterval {
  start: EpochMs;
  end: EpochMs | null;
}

/** 手動で入力した実績進捗。workedMsAtSample は入力時点の累積作業時間（ETA計算の根拠）。 */
export interface ProgressSample {
  value: number; // 0..1
  at: EpochMs;
  workedMsAtSample: number;
}

export interface Task {
  id: Id;
  title: string;
  kind: TaskKind;
  icon: string;
  calendarId: Id | null;
  category: string | null;
  /** 予定に内包されるタスク。値があるタスクはサブタスクを持てない。 */
  eventId: Id | null;
  plannedStart: EpochMs | null;
  plannedEnd: EpochMs | null;
  timeZone: string;
  status: TaskStatus;
  intervals: WorkInterval[];
  actualStart: EpochMs | null;
  actualEnd: EpochMs | null;
  manualProgress: ProgressSample | null;
  /** 一時停止を一度でも経験したか（分析の除外判定に使う） */
  pausedEver: boolean;
  /** AR（自動開始/終了予約）。Phase 2で操作を実装。 */
  autoReserved: boolean;
  /** 確認タスク用 */
  checkAt: EpochMs | null;
  checked: boolean;
  checkedAt: EpochMs | null;
  notes: string;
  createdAt: EpochMs;
  updatedAt: EpochMs;
}

export interface Subtask {
  id: Id;
  taskId: Id;
  title: string;
  done: boolean;
  completedAt: EpochMs | null;
  order: number;
  createdAt: EpochMs;
  updatedAt: EpochMs;
}

export type TaskAction = 'start' | 'pause' | 'resume' | 'finish' | 'undoFinish' | 'undoStart';
