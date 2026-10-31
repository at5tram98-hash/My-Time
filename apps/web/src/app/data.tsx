import { createContext, useContext, useEffect, useMemo, type ReactNode } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import type { CalEvent, Calendar, Subtask, Task } from '@my-time/domain';
import { db, DEFAULT_SETTINGS, type AppSettings } from '../data/db';
import { repo } from '../data/repo';

export interface AppData {
  ready: boolean;
  tasks: Task[];
  events: CalEvent[];
  calendars: Calendar[];
  calendarById: Map<string, Calendar>;
  subtasksByTask: Map<string, Subtask[]>;
  settings: AppSettings;
  outboxPending: number;
}

const EMPTY: Subtask[] = [];
const Ctx = createContext<AppData | null>(null);

export function DataProvider({ children }: { children: ReactNode }) {
  useEffect(() => {
    void repo.ensureDefaults();
  }, []);
  const tasks = useLiveQuery(() => db.tasks.toArray(), []);
  const events = useLiveQuery(() => db.events.toArray(), []);
  const calendars = useLiveQuery(() => db.calendars.orderBy('order').toArray(), []);
  const subtasks = useLiveQuery(() => db.subtasks.orderBy('order').toArray(), []);
  const settingsRow = useLiveQuery(() => db.settings.get('app'), []);
  const outboxPending = useLiveQuery(() => db.outbox.where('synced').equals(0).count(), []);

  const value = useMemo<AppData>(() => {
    const byTask = new Map<string, Subtask[]>();
    for (const s of subtasks ?? []) {
      const arr = byTask.get(s.taskId);
      if (arr) arr.push(s);
      else byTask.set(s.taskId, [s]);
    }
    return {
      ready: tasks !== undefined && events !== undefined && calendars !== undefined,
      tasks: tasks ?? [],
      events: events ?? [],
      calendars: calendars ?? [],
      calendarById: new Map((calendars ?? []).map((c) => [c.id, c])),
      subtasksByTask: byTask,
      settings: { ...DEFAULT_SETTINGS, ...settingsRow },
      outboxPending: outboxPending ?? 0,
    };
  }, [tasks, events, calendars, subtasks, settingsRow, outboxPending]);

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

/** 表示カレンダーがOFFの予定を除外 */
export function useVisibleEvents(): CalEvent[] {
  const { events, calendarById } = useData();
  return useMemo(() => events.filter((e) => calendarById.get(e.calendarId)?.visible !== false), [events, calendarById]);
}
