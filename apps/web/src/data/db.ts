import Dexie, { type EntityTable } from 'dexie';
import type { CalEvent, Calendar, Subtask, Task } from '@my-time/domain';

export interface OperationLogEntry {
  /** 自動採番（同一ミリ秒でも操作順を保証） */
  seq?: number;
  id: string;
  at: number;
  entity: 'task' | 'event' | 'subtask' | 'calendar';
  entityId: string;
  action: string;
  detail?: Record<string, unknown>;
}

/** Phase 2 で Cloudflare に送る未同期キュー。opId は冪等キー。 */
export interface OutboxEntry {
  opId: string;
  at: number;
  entity: 'task' | 'event' | 'subtask' | 'calendar';
  entityId: string;
  op: 'put' | 'delete';
  /** 0 = 未同期（Phase 1 では同期処理なし） */
  synced: 0 | 1;
}

export type ThemePref = 'system' | 'light' | 'dark';
export type TextSizePref = 'system' | 'small' | 'large' | 'xlarge';
export type CalendarViewPref = 'day' | '2day' | 'week' | 'month';

export interface AppSettings {
  key: 'app';
  theme: ThemePref;
  textSize: TextSizePref;
  homeDays: 1 | 2;
  expandedDays: number;
  calendarView: CalendarViewPref;
}

export const DEFAULT_SETTINGS: AppSettings = {
  key: 'app',
  theme: 'system',
  textSize: 'system',
  homeDays: 1,
  expandedDays: 3,
  calendarView: '2day',
};

export class MyTimeDB extends Dexie {
  calendars!: EntityTable<Calendar, 'id'>;
  events!: EntityTable<CalEvent, 'id'>;
  tasks!: EntityTable<Task, 'id'>;
  subtasks!: EntityTable<Subtask, 'id'>;
  operationLog!: EntityTable<OperationLogEntry, 'seq'>;
  outbox!: EntityTable<OutboxEntry, 'opId'>;
  settings!: EntityTable<AppSettings, 'key'>;

  constructor(name = 'my-time') {
    super(name);
    this.version(1).stores({
      calendars: 'id, order',
      events: 'id, start, end, calendarId',
      tasks: 'id, plannedStart, checkAt, status, kind, eventId',
      subtasks: 'id, taskId, order',
      operationLog: '++seq, id, at, entityId',
      outbox: 'opId, at, synced',
      settings: 'key',
    });
  }
}

export const db = new MyTimeDB();
