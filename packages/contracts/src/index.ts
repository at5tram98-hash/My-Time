import { z } from 'zod';
import type { CalEvent, Calendar, Employer, Subject, Subtask, Task } from '@my-time/domain';

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
  visible: z.boolean(),
  order: z.number().int(),
  createdAt: epoch,
  updatedAt: epoch,
});

const freq = z.enum(['daily', 'weekly', 'monthly']);
const text = (n: number) => z.string().max(n);
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
});

export const subjectSchema = z.object({ id, name: z.string().min(1).max(100), createdAt: epoch, updatedAt: epoch });
export const employerSchema = z.object({ id, name: z.string().min(1).max(100), reminderHours: z.number().min(0).max(48), createdAt: epoch, updatedAt: epoch });

/** 同期でやり取りするエンティティ */
export const ENTITY_SCHEMAS = {
  calendar: calendarSchema,
  event: eventSchema,
  task: taskSchema,
  subtask: subtaskSchema,
  subject: subjectSchema,
  employer: employerSchema,
} as const;
export type EntityName = keyof typeof ENTITY_SCHEMAS;
export const ENTITY_NAMES = Object.keys(ENTITY_SCHEMAS) as EntityName[];

export const syncOpSchema = z.object({
  opId: z.string().min(8).max(64),
  entity: z.enum(['calendar', 'event', 'task', 'subtask', 'subject', 'employer']),
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
  results: { opId: string; status: 'applied' | 'duplicate' | 'conflict' | 'rejected'; version: number; serverRecord?: Record<string, unknown> | null; reason?: string }[];
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
] = [true, true, true, true, true, true];
void _checks;
