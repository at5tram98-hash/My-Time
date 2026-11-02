/** 絶対時刻はすべて UTC epoch ミリ秒。表示用のタイムゾーンは別フィールドで保持する。 */
export type EpochMs = number;
export type Id = string;

export type CalendarKind = 'general' | 'class' | 'job';

export interface Calendar {
  id: Id;
  name: string;
  color: string;
  /** 一覧で使うアイコン（安定ID。旧データは絵文字のことがあり、表示時に読み替える） */
  icon: string;
  kind: CalendarKind;
  /** Create Studio で作った専用カレンダーの種類（任意） */
  studioTypeId?: Id | null;
  visible: boolean;
  order: number;
  createdAt: EpochMs;
  updatedAt: EpochMs;
}

export type RecurrenceFreq = 'daily' | 'weekly' | 'monthly';

/** 繰り返しのマスター規則（開始・終了は CalEvent の start/end を初回として使う） */
export interface RecurrenceRule {
  freq: RecurrenceFreq;
  interval: number;
  /** weekly のときの曜日（0=日）。null なら初回と同じ曜日 */
  byWeekday: number[] | null;
  /** この時刻より後に始まる回は作らない（null は無期限） */
  until: EpochMs | null;
}

/** 繰り返しの1回分の例外（その回のみの変更・削除・期限処理済み） */
export interface RecurrenceException {
  /** 規則どおりの開始時刻（回の安定ID） */
  originalStart: EpochMs;
  kind: 'override' | 'cancelled' | 'archived';
  start?: EpochMs;
  end?: EpochMs;
  title?: string;
  notes?: string;
}

export interface ClassAssignment {
  /** 授業内で安定したID（タスクの重複生成防止に使う） */
  key: string;
  title: string;
  content: string;
  submitMethod: string;
  submitTo: string;
  deadline: EpochMs | null;
}

export interface ClassQuiz {
  key: string;
  title: string;
  at: EpochMs | null;
}

export interface ClassInfo {
  subjectId: Id | null;
  subjectName: string;
  room: string;
  assignments: ClassAssignment[];
  quizzes: ClassQuiz[];
}

export interface ExternalSource {
  type: 'timetree' | 'ics' | 'text';
  externalId: string | null;
  fingerprint: string;
  owner: 'me' | 'partner';
  calendarName: string | null;
}

export interface CalEvent {
  /** 拡張項目（任意） */
  extra?: ItemExtra;
  id: Id;
  title: string;
  calendarId: Id;
  start: EpochMs;
  end: EpochMs;
  timeZone: string;
  notes: string;
  recurrence: RecurrenceRule | null;
  exceptions: RecurrenceException[];
  classInfo: ClassInfo | null;
  /** アルバイト：事前登録した勤務先 */
  employerId: Id | null;
  /** 日付をまたぐ予定の特則：終了直後に通常画面から隠す（物理削除はバックアップ確認後） */
  hideAfterEnd: boolean;
  source: ExternalSource | null;
  createdAt: EpochMs;
  updatedAt: EpochMs;
}

export interface Subject {
  id: Id;
  name: string;
  createdAt: EpochMs;
  updatedAt: EpochMs;
}

export interface Employer {
  id: Id;
  name: string;
  /** 勤務開始の何時間前に知らせるか（初期2時間） */
  reminderHours: number;
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

export type SpecialKind = 'normal' | 'assignment' | 'testPrep';

export interface AssignmentInfo {
  content: string;
  submitMethod: string;
  submitTo: string;
  deadline: EpochMs | null;
}

export interface TestPrepInfo {
  /** 試験日時（トグルでオフなら null） */
  examAt: EpochMs | null;
  subjectId: Id | null;
  subjectName: string;
}

export interface TaskRepeat {
  freq: RecurrenceFreq;
  interval: number;
}

export interface Task {
  /** 拡張項目（任意） */
  extra?: ItemExtra;
  id: Id;
  title: string;
  kind: TaskKind;
  special: SpecialKind;
  assignment: AssignmentInfo | null;
  testPrep: TestPrepInfo | null;
  /** 授業から自動生成したときの元の予定（内包ではなく関連付け） */
  sourceEventId: Id | null;
  /** 自動生成の安定キー（同じ課題・小テストから二重に作らない） */
  sourceKey: string | null;
  /** 見積もり作業時間（分）。課題・テスト対策で未入力なら「未設定」 */
  estimateMinutes: number | null;
  priority: 0 | 1 | 2 | 3;
  tags: string[];
  flagged: boolean;
  /** 予定開始（確認タスクは確認日時）の何分前に通知するか。null は通知なし */
  notifyMinutesBefore: number | null;
  location: string | null;
  repeat: TaskRepeat | null;
  /** AR：自動開始・自動終了の予約時刻 */
  autoStartAt: EpochMs | null;
  autoEndAt: EpochMs | null;
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

/** 添付ファイル（本体は Google ドライブ。ここには参照とメタデータだけを持つ：Q80） */
export interface Attachment {
  id: Id;
  name: string;
  mime: string;
  size: number;
  /** Drive のファイルID（アップロード前・オフライン中は null） */
  driveFileId: string | null;
  sha256: string;
  createdAt: EpochMs;
}

export interface PlaceValue {
  name: string;
  address: string;
  lat: number | null;
  lng: number | null;
}

export interface LinkValue {
  id: Id;
  title: string;
  url: string;
}

/** 予定・タスク共通の拡張項目（すべて任意。旧データは extra なしとして扱い、書き換えない） */
export interface ItemExtra {
  /** 予定：終日 */
  allDay?: boolean;
  /** 個別の色（未設定ならカレンダーの色） */
  color?: string | null;
  place?: PlaceValue | null;
  /** 移動時間（分） */
  travelMinutes?: number | null;
  meetingUrl?: string | null;
  /** 通知（開始の何分前）。複数可 */
  notifies?: number[];
  urls?: LinkValue[];
  attachments?: Attachment[];
  /** Create Studio の専用種類と値（項目IDに結びつけた値。表示名を変えても値は保たれる） */
  studio?: { typeId: Id; version: number; values: Record<string, unknown> } | null;
}

/** タスクのカテゴリー（Q55） */
export interface TaskCategory {
  id: Id;
  name: string;
  icon: string;
  color: string;
  order: number;
  createdAt: EpochMs;
  updatedAt: EpochMs;
}

/** ---- Create Studio（Q82〜91・Q84 承認済みの部品）---- */
export type StudioFieldType =
  | 'text' | 'multiline' | 'number' | 'datetime' | 'duration' | 'toggle' | 'check'
  | 'select' | 'multiselect' | 'url' | 'place' | 'file' | 'progress' | 'worktime' | 'note';

export interface StudioField {
  /** 安定ID（名前を変えても値は保たれる） */
  id: Id;
  type: StudioFieldType;
  label: string;
  /** 数値・時間量の単位（標準単位ID または 'custom:<表示名>'） */
  unit?: string | null;
  /** 小数点以下の桁数（数値） */
  precision?: number;
  min?: number | null;
  max?: number | null;
  options?: string[];
  required?: boolean;
  /** 情報確認シートに表示するか */
  showInInfo: boolean;
  /** 所属セクション */
  sectionId: Id;
  /** 説明・区切り（note）の本文 */
  body?: string;
  /** 論理的に非表示（削除しても既存値は保持） */
  hidden?: boolean;
}

export interface StudioSection { id: Id; title: string }

export type StudioProgressMode = 'none' | 'time' | 'number' | 'checklist' | 'manual';

export interface StudioDefinition {
  sections: StudioSection[];
  fields: StudioField[];
  progress: { mode: StudioProgressMode; fieldId: Id | null; target: number | null };
}

export interface StudioType extends StudioDefinition {
  id: Id;
  target: 'calendar' | 'task';
  name: string;
  icon: string;
  color: string;
  /** draft = 下書き（作成・編集画面には出さない）/ active / hidden */
  status: 'draft' | 'active' | 'hidden';
  /** 定義の版。保存のたびに増える */
  version: number;
  /** 変更履歴（旧版の定義。復旧に使う） */
  revisions: { version: number; at: EpochMs; definition: StudioDefinition }[];
  createdAt: EpochMs;
  updatedAt: EpochMs;
}
