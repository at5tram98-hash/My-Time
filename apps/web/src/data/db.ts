import Dexie, { type EntityTable } from 'dexie';
import { normalizeCalendar, normalizeEvent, normalizeTask, type CalEvent, type Calendar, type Employer, type Subject, type Subtask, type Task } from '@my-time/domain';
import type { EntityName } from '@my-time/contracts';

export type SyncEntity = EntityName;

export interface OperationLogEntry {
  /** 自動採番（同一ミリ秒でも操作順を保証） */
  seq?: number;
  id: string;
  at: number;
  entity: SyncEntity;
  entityId: string;
  action: string;
  detail?: Record<string, unknown>;
}

/** クラウドへ送る未同期キュー。opId は冪等キー（再送しても二重に反映されない）。 */
export interface OutboxEntry {
  opId: string;
  at: number;
  entity: SyncEntity;
  entityId: string;
  op: 'put' | 'delete';
  /** 0 = 未同期、1 = サーバーが受領済み */
  synced: 0 | 1;
}

/** サーバー側の版（衝突検出用）と、期間指定復元で一時的に戻したデータの印 */
export interface RecordMeta {
  key: string; // `${entity}:${id}`
  entity: SyncEntity;
  id: string;
  version: number;
  restoredSessionId: string | null;
}

export interface SyncState {
  key: 'sync';
  cursor: number;
  lastSuccessAt: number | null;
  lastAttemptAt: number | null;
  lastError: string | null;
  attempts: number;
  /** 最後にサーバーへ送ったアプリ設定（キー順を固定した JSON）。未送信の変更検出に使う */
  settingsJson?: string | null;
}

/** 端末内だけのお知らせ（同期の失敗など。サーバーのお知らせと一緒に表示） */
export interface LocalNotice {
  key: string;
  level: 'info' | 'warn' | 'error';
  title: string;
  body: string;
  createdAt: number;
  resolvedAt: number | null;
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
  /** 初回セットアップを終えたか */
  onboarded: boolean;
  /** 分析：一時停止経験・自動開始/終了のタスクを含めるか（初期は除外） */
  analysisIncludePaused: boolean;
  analysisIncludeAuto: boolean;
  /** 重複時の空き時間の提案範囲 */
  suggestFromHour: number;
  suggestToHour: number;
  suggestStepMin: 15 | 30 | 60;
  /** 新規タスクの通知（分前、null はなし） */
  defaultNotifyMinutes: number | null;
  /** アルバイトの勤務前リマインダー（新しい勤務先の初期値） */
  defaultJobReminderHours: number;
}

export const DEFAULT_SETTINGS: AppSettings = {
  key: 'app',
  theme: 'system',
  textSize: 'system',
  homeDays: 1,
  expandedDays: 3,
  calendarView: '2day',
  onboarded: false,
  analysisIncludePaused: false,
  analysisIncludeAuto: false,
  suggestFromHour: 7,
  suggestToHour: 23,
  suggestStepMin: 15,
  defaultNotifyMinutes: null,
  defaultJobReminderHours: 2,
};

export class MyTimeDB extends Dexie {
  calendars!: EntityTable<Calendar, 'id'>;
  events!: EntityTable<CalEvent, 'id'>;
  tasks!: EntityTable<Task, 'id'>;
  subtasks!: EntityTable<Subtask, 'id'>;
  subjects!: EntityTable<Subject, 'id'>;
  employers!: EntityTable<Employer, 'id'>;
  operationLog!: EntityTable<OperationLogEntry, 'seq'>;
  outbox!: EntityTable<OutboxEntry, 'opId'>;
  meta!: EntityTable<RecordMeta, 'key'>;
  syncState!: EntityTable<SyncState, 'key'>;
  notices!: EntityTable<LocalNotice, 'key'>;
  settings!: EntityTable<AppSettings, 'key'>;
  recovery!: EntityTable<{ key: string; entity: SyncEntity; id: string; at: number; reason: string; record: Record<string, unknown> }, 'key'>;

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
    // Phase 2：同期・授業/勤務先・お知らせ。既存データは消さず、新しい項目に既定値を補う
    this.version(2)
      .stores({
        subjects: 'id, name',
        employers: 'id, name',
        tasks: 'id, plannedStart, checkAt, status, kind, eventId, sourceKey, sourceEventId',
        outbox: 'opId, at, synced, [entity+entityId]',
        meta: 'key, restoredSessionId',
        syncState: 'key',
        notices: 'key, resolvedAt',
      })
      .upgrade(async (tx) => {
        await tx.table('tasks').toCollection().modify((t: Task) => Object.assign(t, normalizeTask(t)));
        await tx.table('events').toCollection().modify((e: CalEvent) => Object.assign(e, normalizeEvent(e)));
        await tx.table('calendars').toCollection().modify((c: Calendar) => Object.assign(c, normalizeCalendar(c)));
        // 既存の設定で初めて起動した人には初回セットアップを出さない
        await tx.table('settings').toCollection().modify((s: AppSettings) => Object.assign(s, { ...DEFAULT_SETTINGS, ...s, onboarded: true }));
      });
    this.version(3).stores({ recovery: 'key, at' });
  }
}

// ---------------- アカウントごとの保存領域 ----------------
// 端末内のデータはアカウントごとに別の IndexedDB に分ける。
//   'my-time'            … ログインしていない間のデータ（この端末だけ。Phase 1 からのデータもここ）
//   'my-time@<ユーザーID>' … そのアカウントのデータ（このアカウントでログイン中だけ送受信する）
// 別のアカウントでログインしても、前のアカウントのデータ（未送信の変更を含む）は自動で送らず、そのまま残す。

export const LOCAL_DB = 'my-time';
const ACCOUNT_PREFIX = 'my-time@';
export const ACTIVE_DB_KEY = 'mytime:activeDb';
/** 切り替え後の画面に一度だけ出す案内 */
export const FLASH_KEY = 'mytime:flash';

export const accountDbName = (userId: string) => `${ACCOUNT_PREFIX}${userId}`;
/** 保存領域の持ち主（ログインしていない間の領域なら null） */
export const ownerOf = (dbName: string): string | null => (dbName.startsWith(ACCOUNT_PREFIX) ? dbName.slice(ACCOUNT_PREFIX.length) : null);

function storageGet(k: string): string | null {
  try {
    return localStorage.getItem(k);
  } catch {
    return null;
  }
}

/** いま表示する保存領域（端末に記憶。読めないときはログインしていない領域） */
export function activeDbName(): string {
  const v = storageGet(ACTIVE_DB_KEY);
  return v === LOCAL_DB || (v && ownerOf(v)) ? v : LOCAL_DB;
}

/** 保存領域を切り替えて再読み込みする（画面・同期のすべてが新しい領域で始まる） */
export function switchActiveDb(name: string, flash?: string): void {
  try {
    localStorage.setItem(ACTIVE_DB_KEY, name);
    if (flash) localStorage.setItem(FLASH_KEY, flash);
  } catch {
    /* 保存できない環境では切り替えられない（ログインしていない領域のまま） */
  }
  location.reload();
}

export function takeFlash(): string | null {
  const v = storageGet(FLASH_KEY);
  if (v) {
    try {
      localStorage.removeItem(FLASH_KEY);
    } catch {
      /* noop */
    }
  }
  return v;
}

export const db = new MyTimeDB(activeDbName());
