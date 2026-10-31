import { z } from 'zod';
import type { CalEvent, Calendar, Subtask, Task } from '@my-time/domain';

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
  kind: z.enum(['general', 'class', 'job']),
  visible: z.boolean(),
  order: z.number().int(),
  createdAt: epoch,
  updatedAt: epoch,
});

export const eventSchema = z
  .object({
    id,
    title: z.string().min(1).max(200),
    calendarId: id,
    start: epoch,
    end: epoch,
    timeZone: z.string().min(1),
    notes: z.string().max(10_000),
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

// 型とスキーマのずれをコンパイル時に検出する
type Same<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;
const _checks: [
  Same<z.infer<typeof calendarSchema>, Calendar>,
  Same<z.infer<typeof eventSchema>, CalEvent>,
  Same<z.infer<typeof taskSchema>, Task>,
  Same<z.infer<typeof subtaskSchema>, Subtask>,
] = [true, true, true, true];
void _checks;
