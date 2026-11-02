import { z } from 'zod';
import type { CalEvent, Calendar, Employer, StudioType, Subject, Subtask, Task, TaskCategory } from '@my-time/domain';

/**
 * 永続化・将来のAPI同期（Phase 2）で使う入力検証スキーマ。
 * 外部由来のデータ（インポート・同期レスポンス）は必ずここを通す。
 */
const epoch = z.number().int().nonnegative();
const id = z.string().min(1).max(128);

export const calendarSchema = z.object({
  id,
  name: z.string().min(1).max(60),
  color: z.string().regex(/^#[0-9a-fA-F]{6}$/),
  icon: z.string().min(1).max(16),
  kind: z.enum(['general', 'class', 'job']),
  studioTypeId: id.nullable().optional(),
  visible: z.boolean(),
  order: z.number().int(),
  createdAt: epoch,
  updatedAt: epoch,
});


const text = (n: number) => z.string().max(n);
const color = z.string().regex(/^#[0-9a-fA-F]{6}$/);
const urlText = z.string().max(2000);
/** 予定・タスク共通の拡張項目（すべて任意：旧クライアント・旧データと互換） */
export const extraSchema = z.object({
  allDay: z.boolean().optional(),
  color: color.nullable().optional(),
  place: z.object({ name: text(200), address: text(500), lat: z.number().min(-90).max(90).nullable(), lng: z.number().min(-180).max(180).nullable() }).nullable().optional(),
  travelMinutes: z.number().int().min(0).max(1440).nullable().optional(),
  meetingUrl: urlText.nullable().optional(),
  notifies: z.array(z.number().int().min(0).max(40_320)).max(10).optional(),
  urls: z.array(z.object({ id, title: text(200), url: urlText })).max(30).optional(),
  attachments: z.array(z.object({ id, name: text(255), mime: text(100), size: z.number().int().nonnegative().max(50 * 1024 * 1024), driveFileId: text(200).nullable(), sha256: text(64), createdAt: epoch })).max(30).optional(),
  studio: z.object({ typeId: id, version: z.number().int().min(1), values: z.record(z.string().max(128), z.unknown()) }).nullable().optional(),
}).optional();

const freq = z.enum(['daily', 'weekly', 'monthly']);
export const recurrenceSchema = z.object({ freq, interval: z.number().int().min(1).max(99), byWeekday: z.array(z.number().int().min(0).max(6)).max(7).nullable(), until: epoch.nullable() });
const exceptionSchema = z.object({
  originalStart: epoch,
  kind: z.enum(['override', 'cancelled', 'archived']),
  start: epoch.optional(),
  end: epoch.optional(),
  title: text(200).optional(),
  notes: text(10_000).optional(),
});
const classInfoSchema = z.object({
  subjectId: id.nullable(),
  subjectName: text(100),
  room: text(100),
  assignments: z.array(z.object({ key: id, title: text(200), content: text(5000), submitMethod: text(200), submitTo: text(200), deadline: epoch.nullable() })).max(100),
  quizzes: z.array(z.object({ key: id, title: text(200), at: epoch.nullable() })).max(100),
});
const sourceSchema = z.object({ type: z.enum(['timetree', 'ics', 'text']), externalId: text(500).nullable(), fingerprint: text(1000), owner: z.enum(['me', 'partner']), calendarName: text(200).nullable() });

export const eventSchema = z
  .object({
    id,
    title: z.string().min(1).max(200),
    calendarId: id,
    start: epoch,
    end: epoch,
    timeZone: z.string().min(1),
    notes: z.string().max(10_000),
    recurrence: recurrenceSchema.nullable(),
    exceptions: z.array(exceptionSchema).max(2000),
    classInfo: classInfoSchema.nullable(),
    employerId: id.nullable(),
    hideAfterEnd: z.boolean(),
    source: sourceSchema.nullable(),
    extra: extraSchema,
    createdAt: epoch,
    updatedAt: epoch,
  })
  .refine((e) => e.end > e.start, { message: '終了は開始より後にしてください', path: ['end'] });

const interval = z.object({ start: epoch, end: epoch.nullable() });

export const taskSchema = z
  .object({
    id,
    title: z.string().min(1).max(200),
    kind: z.enum(['do', 'check']),
    special: z.enum(['normal', 'assignment', 'testPrep']),
    assignment: z.object({ content: text(5000), submitMethod: text(200), submitTo: text(200), deadline: epoch.nullable() }).nullable(),
    testPrep: z.object({ examAt: epoch.nullable(), subjectId: id.nullable(), subjectName: text(100) }).nullable(),
    sourceEventId: id.nullable(),
    sourceKey: text(300).nullable(),
    estimateMinutes: z.number().int().min(1).max(10_000).nullable(),
    priority: z.union([z.literal(0), z.literal(1), z.literal(2), z.literal(3)]),
    tags: z.array(text(40)).max(30),
    flagged: z.boolean(),
    notifyMinutesBefore: z.number().int().min(0).max(10_080).nullable(),
    location: text(200).nullable(),
    repeat: z.object({ freq, interval: z.number().int().min(1).max(99) }).nullable(),
    autoStartAt: epoch.nullable(),
    autoEndAt: epoch.nullable(),
    icon: z.string().min(1).max(16),
    calendarId: id.nullable(),
    category: z.string().max(40).nullable(),
    eventId: id.nullable(),
    plannedStart: epoch.nullable(),
    plannedEnd: epoch.nullable(),
    timeZone: z.string().min(1),
    status: z.enum(['notStarted', 'running', 'paused', 'done']),
    intervals: z.array(interval),
    actualStart: epoch.nullable(),
    actualEnd: epoch.nullable(),
    manualProgress: z.object({ value: z.number().min(0).max(1), at: epoch, workedMsAtSample: z.number().nonnegative() }).nullable(),
    pausedEver: z.boolean(),
    autoReserved: z.boolean(),
    checkAt: epoch.nullable(),
    checked: z.boolean(),
    checkedAt: epoch.nullable(),
    notes: z.string().max(10_000),
    extra: extraSchema,
    createdAt: epoch,
    updatedAt: epoch,
  })
  .refine((t) => t.plannedStart == null || t.plannedEnd == null || t.plannedEnd > t.plannedStart, {
    message: '終了は開始より後にしてください',
    path: ['plannedEnd'],
  });

export const subtaskSchema = z.object({
  id,
  taskId: id,
  title: z.string().min(1).max(200),
  done: z.boolean(),
  completedAt: epoch.nullable(),
  order: z.number().int(),
  createdAt: epoch,
  updatedAt: epoch,
  // C07：サブタスクの日時と見積（任意。旧データは省略）
  plannedStart: epoch.nullable().optional(),
  plannedEnd: epoch.nullable().optional(),
  estimateMinutes: z.number().positive().max(100_000).nullable().optional(),
}).refine((s) => !(s.plannedEnd != null && s.plannedStart == null), { message: '終了だけは設定できません' })
  .refine((s) => s.plannedStart == null || s.plannedEnd == null || s.plannedEnd > s.plannedStart, { message: '終了は開始より後にしてください' });

export const subjectSchema = z.object({ id, name: z.string().min(1).max(100), createdAt: epoch, updatedAt: epoch });
export const employerSchema = z.object({ id, name: z.string().min(1).max(100), reminderHours: z.number().min(0).max(48), createdAt: epoch, updatedAt: epoch });

export const categorySchema = z.object({ id, name: z.string().min(1).max(40), icon: z.string().min(1).max(16), color, order: z.number().int(), createdAt: epoch, updatedAt: epoch });

const studioFieldSchema = z.object({
  id,
  type: z.enum(['text', 'multiline', 'number', 'datetime', 'duration', 'toggle', 'check', 'select', 'multiselect', 'url', 'place', 'file', 'progress', 'worktime', 'note']),
  label: z.string().min(1).max(60),
  unit: text(40).nullable().optional(),
  precision: z.number().int().min(0).max(4).optional(),
  min: z.number().nullable().optional(),
  max: z.number().nullable().optional(),
  options: z.array(text(60)).max(50).optional(),
  required: z.boolean().optional(),
  showInInfo: z.boolean(),
  sectionId: id,
  body: text(2000).optional(),
  hidden: z.boolean().optional(),
});
const studioDefinitionSchema = z.object({
  sections: z.array(z.object({ id, title: text(60) })).max(20),
  fields: z.array(studioFieldSchema).max(60),
  progress: z.object({ mode: z.enum(['none', 'time', 'number', 'checklist', 'manual']), fieldId: id.nullable(), target: z.number().nullable() }),
});
export const studioTypeSchema = studioDefinitionSchema.extend({
  id,
  target: z.enum(['calendar', 'task']),
  name: z.string().min(1).max(40),
  icon: z.string().min(1).max(16),
  color,
  status: z.enum(['draft', 'active', 'hidden']),
  version: z.number().int().min(1),
  revisions: z.array(z.object({ version: z.number().int().min(1), at: epoch, definition: studioDefinitionSchema })).max(50),
  createdAt: epoch,
  updatedAt: epoch,
});

/** 同期でやり取りするエンティティ */
export const ENTITY_SCHEMAS = {
  calendar: calendarSchema,
  event: eventSchema,
  task: taskSchema,
  subtask: subtaskSchema,
  subject: subjectSchema,
  employer: employerSchema,
  category: categorySchema,
  studioType: studioTypeSchema,
} as const;
export type EntityName = keyof typeof ENTITY_SCHEMAS;
export const ENTITY_NAMES = Object.keys(ENTITY_SCHEMAS) as EntityName[];

export const syncOpSchema = z.object({
  opId: z.string().min(8).max(64),
  entity: z.enum(['calendar', 'event', 'task', 'subtask', 'subject', 'employer', 'category', 'studioType']),
  entityId: id,
  op: z.enum(['put', 'delete']),
  /** put のときの最新レコード（検証は entity ごとのスキーマで行う） */
  record: z.record(z.unknown()).nullable(),
  /** クライアントが最後に見たサーバー版（衝突検出）。新規は 0 */
  baseVersion: z.number().int().min(0),
  clientUpdatedAt: epoch,
});
export type SyncOp = z.infer<typeof syncOpSchema>;
export const pushRequestSchema = z.object({ ops: z.array(syncOpSchema).max(500) });

export interface PushResult {
  results: {
    opId: string;
    status: 'applied' | 'duplicate' | 'conflict' | 'rejected' | 'retry';
    version: number;
    /** conflict のときのサーバーの最新（削除済みなら null） */
    serverRecord?: Record<string, unknown> | null;
    /** conflict のとき：サーバーでは削除済み（tombstone）。端末の変更より常に優先される */
    serverDeleted?: boolean;
    /** 削除済みの理由（serverDeleted のとき） */
    deleteReason?: 'user' | 'purge' | 'restore-end' | null;
    reason?: string;
  }[];
}

export interface PullChange {
  entity: EntityName;
  id: string;
  version: number;
  deleted: boolean;
  /** 削除理由：ユーザー操作 / 期限削除（バックアップ確認済み）/ 復元閲覧の終了 */
  reason: 'user' | 'purge' | 'restore-end' | null;
  record: Record<string, unknown> | null;
  restoredSessionId: string | null;
}
export interface PullResult {
  /** Changes after a full server recovery require a fresh pull from zero. */
  generation?: string;
  cursor: number;
  changes: PullChange[];
  hasMore: boolean;
}

// 型とスキーマのずれをコンパイル時に検出する
type Same<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
const _checks: [
  Same<z.infer<typeof subjectSchema>, Subject>,
  Same<z.infer<typeof employerSchema>, Employer>,
  Same<z.infer<typeof calendarSchema>, Calendar>,
  Same<z.infer<typeof eventSchema>, CalEvent>,
  Same<z.infer<typeof taskSchema>, Task>,
  Same<z.infer<typeof subtaskSchema>, Subtask>,
  Same<z.infer<typeof categorySchema>, TaskCategory>,
  Same<z.infer<typeof studioTypeSchema>, StudioType>,
] = [true, true, true, true, true, true, true, true];
void _checks;
