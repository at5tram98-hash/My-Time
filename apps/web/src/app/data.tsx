import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import { expandAll, hiddenAfterEnd, normalizeCalendar, normalizeEvent, normalizeTask, type CalEvent, type Calendar, type Employer, type Occurrence, type Subject, type Subtask, type Task } from '@my-time/domain';
import { db, DEFAULT_SETTINGS, type AppSettings, type LocalNotice } from '../data/db';
import { repo } from '../data/repo';
import { syncEngine, type SyncStatus } from '../sync/engine';

export interface AppData {
  ready: boolean;
  tasks: Task[];
  events: CalEvent[];
  calendars: Calendar[];
  calendarById: Map<string, Calendar>;
  subtasksByTask: Map<string, Subtask[]>;
  subjects: Subject[];
  employers: Employer[];
  settings: AppSettings;
  outboxPending: number;
  /** 期間指定復元で一時的に表示している記録（`${entity}:${id}`） */
  restoredKeys: Set<string>;
  localNotices: LocalNotice[];
}

const EMPTY: Subtask[] = [];
const Ctx = createContext<AppData | null>(null);

export function DataProvider({ children }: { children: ReactNode }) {
  useEffect(() => {
    void repo.ensureDefaults();
  }, []);
  // 読み込み時にも既定値を補う（古い形式・外部から入った記録でも画面が壊れないように）
  const tasks = useLiveQuery(async () => (await db.tasks.toArray()).map(normalizeTask), []);
  const events = useLiveQuery(async () => (await db.events.toArray()).map(normalizeEvent), []);
  const calendars = useLiveQuery(async () => (await db.calendars.orderBy('order').toArray()).map(normalizeCalendar), []);
  const subtasks = useLiveQuery(() => db.subtasks.orderBy('order').toArray(), []);
  const subjects = useLiveQuery(() => db.subjects.orderBy('name').toArray(), []);
  const employers = useLiveQuery(() => db.employers.orderBy('name').toArray(), []);
  const settingsRow = useLiveQuery(async () => (await db.settings.get('app')) ?? null, []);
  const outboxPending = useLiveQuery(() => db.outbox.where('synced').equals(0).count(), []);
  const restored = useLiveQuery(() => db.meta.filter((m) => m.restoredSessionId != null).toArray(), []);
  const localNotices = useLiveQuery(() => db.notices.toArray(), []);

  const value = useMemo<AppData>(() => {
    const byTask = new Map<string, Subtask[]>();
    for (const s of subtasks ?? []) {
      const arr = byTask.get(s.taskId);
      if (arr) arr.push(s);
      else byTask.set(s.taskId, [s]);
    }
    return {
      ready: tasks !== undefined && events !== undefined && calendars !== undefined && settingsRow !== undefined,
      tasks: tasks ?? [],
      events: events ?? [],
      calendars: calendars ?? [],
      calendarById: new Map((calendars ?? []).map((c) => [c.id, c])),
      subtasksByTask: byTask,
      subjects: subjects ?? [],
      employers: employers ?? [],
      settings: { ...DEFAULT_SETTINGS, ...settingsRow },
      outboxPending: outboxPending ?? 0,
      restoredKeys: new Set((restored ?? []).map((m) => m.key)),
      localNotices: localNotices ?? [],
    };
  }, [tasks, events, calendars, subtasks, subjects, employers, settingsRow, outboxPending, restored, localNotices]);

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useData(): AppData {
  const v = useContext(Ctx);
  if (!v) throw new Error('DataProvider がありません');
  return v;
}

export function useSubtasks(taskId: string): Subtask[] {
  return useData().subtasksByTask.get(taskId) ?? EMPTY;
}

/**
 * 表示する予定（指定範囲）。繰り返しは各回に展開し、
 * 非表示カレンダーと「終了直後に隠す」特則の予定（復元閲覧中を除く）は除外する。
 */
export function useVisibleEvents(from: number, to: number, now: number): (CalEvent | Occurrence)[] {
  const { events, calendarById, restoredKeys } = useData();
  return useMemo(() => {
    const shown = events.filter((e) => calendarById.get(e.calendarId)?.visible !== false && (restoredKeys.has(`event:${e.id}`) || !hiddenAfterEnd(e, now)));
    return expandAll(shown, from, to);
  }, [events, calendarById, restoredKeys, from, to, now]);
}

export function useSync(): SyncStatus {
  const [s, setS] = useState(syncEngine.snapshot);
  useEffect(() => syncEngine.subscribe(setS), []);
  return s;
}

/** 「その他」タブの「!」：未解決の警告・エラーがあるか */
export function useAttention(): number {
  const { localNotices } = useData();
  const sync = useSync();
  return localNotices.filter((n) => n.resolvedAt == null && n.level !== 'info').length + sync.notices.filter((n) => n.resolved_at == null && n.level !== 'info').length;
}
