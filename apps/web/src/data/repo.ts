import {
  applyTaskAction, canAddSubtask, convertKind, defaultCalendars, makeSubtask, newId, recordManualProgress, toggleCheck,
  toggleSubtask, type CalEvent, type Subtask, type Task, type TaskAction, type TaskKind, type TaskTransition,
} from '@my-time/domain';
import { eventSchema, subtaskSchema, taskSchema } from '@my-time/contracts';
import { db, DEFAULT_SETTINGS, type AppSettings, type MyTimeDB, type OperationLogEntry, type OutboxEntry } from './db';

/**
 * ローカル永続化の唯一の書き込み口。
 * 1回の操作 = 1トランザクション（本体 + 操作ログ + 未同期キュー）。
 * Phase 2 ではこのキューを Cloudflare Workers 同期に接続する。
 */
export function createRepo(database: MyTimeDB = db, clock: () => number = Date.now) {
  const record = async (entity: OutboxEntry['entity'], entityId: string, op: OutboxEntry['op'], action: string, detail?: Record<string, unknown>) => {
    const at = clock();
    const log: OperationLogEntry = { id: newId(), at, entity, entityId, action, ...(detail ? { detail } : {}) };
    await database.operationLog.add(log);
    await database.outbox.add({ opId: newId(), at, entity, entityId, op, synced: 0 });
  };

  const tx = <T>(fn: () => Promise<T>) =>
    database.transaction('rw', [database.tasks, database.events, database.subtasks, database.calendars, database.operationLog, database.outbox], fn);

  const getTask = async (id: string) => {
    const t = await database.tasks.get(id);
    if (!t) throw new Error('タスクが見つかりません');
    return t;
  };

  const applyTransition = async (tr: TaskTransition) => {
    taskSchema.parse(tr.task);
    await database.tasks.put(tr.task);
    await record('task', tr.task.id, 'put', tr.log.action, { from: tr.log.from, to: tr.log.to, ...tr.log.detail });
    return tr.task;
  };

  return {
    /** 既定カレンダーは空のときだけ作る。既存データは決して上書きしない。 */
    async ensureDefaults() {
      await tx(async () => {
        if ((await database.calendars.count()) === 0) await database.calendars.bulkAdd(defaultCalendars(clock()));
      });
    },

    async saveTask(task: Task, isNew: boolean) {
      const t = { ...task, updatedAt: clock() };
      taskSchema.parse(t);
      return tx(async () => {
        if (t.eventId != null && (await database.subtasks.where('taskId').equals(t.id).count()) > 0) {
          throw new Error('予定に内包されるタスクはサブタスクを持てません');
        }
        await database.tasks.put(t);
        await record('task', t.id, 'put', isNew ? 'create' : 'update');
        return t;
      });
    },

    async deleteTask(id: string) {
      return tx(async () => {
        const subs = await database.subtasks.where('taskId').equals(id).primaryKeys();
        await database.subtasks.bulkDelete(subs);
        await database.tasks.delete(id);
        await record('task', id, 'delete', 'delete', { subtasks: subs.length });
      });
    },

    async taskAction(id: string, action: TaskAction) {
      return tx(async () => applyTransition(applyTaskAction(await getTask(id), action, clock())));
    },

    async recordProgress(id: string, value: number) {
      return tx(async () => {
        const subs = await database.subtasks.where('taskId').equals(id).toArray();
        return applyTransition(recordManualProgress(await getTask(id), subs, value, clock()));
      });
    },

    /** 100%確認後の完了：実績100%を記録してから終了する（1トランザクション） */
    async completeFromProgress(id: string) {
      return tx(async () => {
        let t = await getTask(id);
        const now = clock();
        t = await applyTransition(recordManualProgress(t, [], 1, now));
        if (t.status === 'notStarted') t = await applyTransition(applyTaskAction(t, 'start', now));
        if (t.status === 'paused') t = await applyTransition(applyTaskAction(t, 'resume', now));
        return applyTransition(applyTaskAction(t, 'finish', now));
      });
    },

    async toggleCheck(id: string) {
      return tx(async () => applyTransition(toggleCheck(await getTask(id), clock())));
    },

    async convertTask(id: string, to: TaskKind) {
      return tx(async () => applyTransition(convertKind(await getTask(id), to, clock())));
    },

    async addSubtask(taskId: string, title: string) {
      return tx(async () => {
        const task = await getTask(taskId);
        if (!canAddSubtask(task)) throw new Error('このタスクにはサブタスクを追加できません');
        const order = await database.subtasks.where('taskId').equals(taskId).count();
        const s = makeSubtask(taskId, title.trim(), order, clock());
        subtaskSchema.parse(s);
        await database.subtasks.add(s);
        await record('subtask', s.id, 'put', 'create', { taskId });
        return s;
      });
    },

    async toggleSubtask(id: string) {
      return tx(async () => {
        const s = await database.subtasks.get(id);
        if (!s) throw new Error('サブタスクが見つかりません');
        const n: Subtask = toggleSubtask(s, clock());
        await database.subtasks.put(n);
        await record('subtask', id, 'put', n.done ? 'complete' : 'uncomplete', { taskId: s.taskId });
        return n;
      });
    },

    async deleteSubtask(id: string) {
      return tx(async () => {
        await database.subtasks.delete(id);
        await record('subtask', id, 'delete', 'delete');
      });
    },

    async saveEvent(ev: CalEvent, isNew: boolean) {
      const e = { ...ev, updatedAt: clock() };
      eventSchema.parse(e);
      return tx(async () => {
        await database.events.put(e);
        await record('event', e.id, 'put', isNew ? 'create' : 'update');
        return e;
      });
    },

    /** 時間軸のドラッグ移動（呼び出し側で15分スナップ済み）。長さは保持。 */
    async moveEvent(id: string, newStart: number) {
      return tx(async () => {
        const e = await database.events.get(id);
        if (!e) throw new Error('予定が見つかりません');
        const n = { ...e, start: newStart, end: newStart + (e.end - e.start), updatedAt: clock() };
        await database.events.put(n);
        await record('event', id, 'put', 'move', { from: e.start, to: newStart });
        return n;
      });
    },

    async moveTask(id: string, newStart: number) {
      return tx(async () => {
        const t = await getTask(id);
        if (t.plannedStart == null || t.plannedEnd == null) throw new Error('予定時刻がありません');
        const n = { ...t, plannedStart: newStart, plannedEnd: newStart + (t.plannedEnd - t.plannedStart), updatedAt: clock() };
        await database.tasks.put(n);
        await record('task', id, 'put', 'move', { from: t.plannedStart, to: newStart });
        return n;
      });
    },

    async deleteEvent(id: string) {
      return tx(async () => {
        await database.events.delete(id);
        await record('event', id, 'delete', 'delete');
      });
    },

    async getSettings(): Promise<AppSettings> {
      return { ...DEFAULT_SETTINGS, ...(await database.settings.get('app')) };
    },

    async updateSettings(patch: Partial<Omit<AppSettings, 'key'>>) {
      const cur = await this.getSettings();
      await database.settings.put({ ...cur, ...patch, key: 'app' });
    },
  };
}

export type Repo = ReturnType<typeof createRepo>;
export const repo = createRepo();
