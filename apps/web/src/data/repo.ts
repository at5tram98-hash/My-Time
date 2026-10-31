import {
  addDays, addMonths, applyAutoReservation, applyTaskAction, canAddSubtask, cancelThisOccurrence, convertKind, copyToDays, defaultCalendars,
  editThisOccurrence, makeEvent, makeSubtask, newId, planClassTasks, recordManualProgress, splitFromOccurrence, toggleCheck, toggleSubtask,
  type CalEvent, type Calendar, type Employer, type ImportCandidate, type Subject, type Subtask, type Task, type TaskAction, type TaskKind, type TaskTransition,
} from '@my-time/domain';
import { calendarSchema, employerSchema, eventSchema, subjectSchema, subtaskSchema, taskSchema } from '@my-time/contracts';
import { db, DEFAULT_SETTINGS, type AppSettings, type MyTimeDB, type OperationLogEntry, type OutboxEntry } from './db';

/** ローカルで書き込みがあったことを同期エンジンへ知らせる */
export const localChanges = new EventTarget();

/**
 * ローカル永続化の唯一の書き込み口。
 * 1回の操作 = 1トランザクション（本体 + 操作ログ + 未同期キュー）。
 * 未同期キューは sync/engine.ts が Cloudflare Workers へ送る（オフラインでも書き込める）。
 */
export function createRepo(database: MyTimeDB = db, clock: () => number = Date.now) {
  const record = async (entity: OutboxEntry['entity'], entityId: string, op: OutboxEntry['op'], action: string, detail?: Record<string, unknown>) => {
    const at = clock();
    const log: OperationLogEntry = { id: newId(), at, entity, entityId, action, ...(detail ? { detail } : {}) };
    await database.operationLog.add(log);
    await database.outbox.add({ opId: newId(), at, entity, entityId, op, synced: 0 });
    queueMicrotask(() => localChanges.dispatchEvent(new Event('change')));
  };

  const tx = <T>(fn: () => Promise<T>) =>
    database.transaction('rw', [database.tasks, database.events, database.subtasks, database.calendars, database.subjects, database.employers, database.operationLog, database.outbox], fn);

  /** 繰り返しタスクを完了したら次の回を作る（Reminders と同じ考え方） */
  const nextRepeat = async (t: Task, now: number) => {
    if (!t.repeat || t.status !== 'done') return;
    const shift = (x: number | null) => (x == null ? null : t.repeat!.freq === 'monthly' ? addMonths(x, t.repeat!.interval) : addDays(x, (t.repeat!.freq === 'weekly' ? 7 : 1) * t.repeat!.interval));
    const next: Task = {
      ...t,
      id: newId(),
      status: 'notStarted',
      intervals: [],
      actualStart: null,
      actualEnd: null,
      manualProgress: null,
      pausedEver: false,
      autoReserved: false,
      checked: false,
      checkedAt: null,
      plannedStart: shift(t.plannedStart),
      plannedEnd: shift(t.plannedEnd),
      checkAt: shift(t.checkAt),
      sourceKey: null,
      createdAt: now,
      updatedAt: now,
    };
    taskSchema.parse(next);
    await database.tasks.put(next);
    await record('task', next.id, 'put', 'repeat', { from: t.id });
  };

  const getTask = async (id: string) => {
    const t = await database.tasks.get(id);
    if (!t) throw new Error('タスクが見つかりません');
    return t;
  };

  const applyTransition = async (tr: TaskTransition) => {
    taskSchema.parse(tr.task);
    await database.tasks.put(tr.task);
    await record('task', tr.task.id, 'put', tr.log.action, { from: tr.log.from, to: tr.log.to, ...tr.log.detail });
    if ((tr.log.action === 'finish' || tr.log.action === 'check') && tr.task.repeat) await nextRepeat(tr.task, tr.log.at);
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


    // ---------------- カレンダー・科目・勤務先 ----------------
    async saveCalendar(cal: Calendar, isNew: boolean) {
      const c = { ...cal, updatedAt: clock() };
      calendarSchema.parse(c);
      return tx(async () => {
        await database.calendars.put(c);
        await record('calendar', c.id, 'put', isNew ? 'create' : 'update');
        return c;
      });
    },

    /** 予定・タスクが残っているカレンダーは削除しない（データを勝手に移動・削除しない） */
    async deleteCalendar(id: string) {
      return tx(async () => {
        const n = (await database.events.where('calendarId').equals(id).count()) + (await database.tasks.filter((t) => t.calendarId === id).count());
        if (n > 0) throw new Error(`このカレンダーには予定・タスクが${n}件あります。先に移動または削除してください`);
        if ((await database.calendars.count()) <= 1) throw new Error('最後のカレンダーは削除できません');
        await database.calendars.delete(id);
        await record('calendar', id, 'delete', 'delete');
      });
    },

    async reorderCalendars(ids: string[]) {
      return tx(async () => {
        const now = clock();
        for (const [i, id] of ids.entries()) {
          const c = await database.calendars.get(id);
          if (c && c.order !== i) {
            await database.calendars.put({ ...c, order: i, updatedAt: now });
            await record('calendar', id, 'put', 'reorder');
          }
        }
      });
    },

    async saveSubject(sub: Subject, isNew: boolean) {
      const s2 = { ...sub, updatedAt: clock() };
      subjectSchema.parse(s2);
      return tx(async () => {
        await database.subjects.put(s2);
        await record('subject', s2.id, 'put', isNew ? 'create' : 'update');
        return s2;
      });
    },
    async deleteSubject(id: string) {
      return tx(async () => {
        await database.subjects.delete(id);
        await record('subject', id, 'delete', 'delete');
      });
    },
    async saveEmployer(e: Employer, isNew: boolean) {
      const e2 = { ...e, updatedAt: clock() };
      employerSchema.parse(e2);
      return tx(async () => {
        await database.employers.put(e2);
        await record('employer', e2.id, 'put', isNew ? 'create' : 'update');
        return e2;
      });
    },
    async deleteEmployer(id: string) {
      return tx(async () => {
        await database.employers.delete(id);
        await record('employer', id, 'delete', 'delete');
      });
    },

    // ---------------- 授業の課題・小テスト → 独立タスク ----------------
    /**
     * 授業の予定を保存し、ユーザーが承認した場合だけ課題・テスト対策タスクを作る（安定キーで重複しない）。
     * 授業側の期限などが変わったタスクは内容を更新する。
     */
    async saveEventWithClassTasks(ev: CalEvent, isNew: boolean, createTasks: boolean) {
      const e = { ...ev, updatedAt: clock() };
      eventSchema.parse(e);
      return tx(async () => {
        await database.events.put(e);
        await record('event', e.id, 'put', isNew ? 'create' : 'update');
        if (!e.classInfo) return { event: e, created: 0, updated: 0 };
        const existing = await database.tasks.where('sourceEventId').equals(e.id).toArray();
        const plan = planClassTasks(e, existing, clock());
        for (const t of plan.update) {
          await database.tasks.put(t);
          await record('task', t.id, 'put', 'class-update', { sourceEventId: e.id });
        }
        if (!createTasks) return { event: e, created: 0, updated: plan.update.length };
        for (const t of plan.create) {
          taskSchema.parse(t);
          await database.tasks.put(t);
          await record('task', t.id, 'put', 'class-create', { sourceEventId: e.id, sourceKey: t.sourceKey });
        }
        return { event: e, created: plan.create.length, updated: plan.update.length };
      });
    },

    // ---------------- 繰り返し予定 ----------------
    /** 繰り返しの1回を変更（この回のみ / これ以降すべて）。過去の回・元のマスターは保護 */
    async editOccurrence(masterId: string, originalStart: number, patch: Partial<Omit<CalEvent, 'id' | 'createdAt' | 'updatedAt' | 'exceptions'>>, scope: 'this' | 'future') {
      return tx(async () => {
        const m = await database.events.get(masterId);
        if (!m) throw new Error('予定が見つかりません');
        const now = clock();
        if (scope === 'this') {
          const { start, end, title, notes } = patch;
          const next = editThisOccurrence(m, originalStart, { ...(start != null ? { start } : {}), ...(end != null ? { end } : {}), ...(title != null ? { title } : {}), ...(notes != null ? { notes } : {}) }, now);
          eventSchema.parse(next);
          await database.events.put(next);
          await record('event', m.id, 'put', 'occurrence-edit', { originalStart });
          return;
        }
        const { before, after } = splitFromOccurrence(m, originalStart, patch, newId(), now);
        eventSchema.parse(after);
        if (before) {
          eventSchema.parse(before);
          await database.events.put(before);
          await record('event', before.id, 'put', 'series-split', { originalStart });
        } else {
          await database.events.delete(m.id);
          await record('event', m.id, 'delete', 'series-replace');
        }
        await database.events.put(after);
        await record('event', after.id, 'put', 'series-create', { from: m.id });
      });
    },

    async deleteOccurrence(masterId: string, originalStart: number, scope: 'this' | 'future') {
      return tx(async () => {
        const m = await database.events.get(masterId);
        if (!m || !m.recurrence) throw new Error('予定が見つかりません');
        const now = clock();
        if (scope === 'this' || originalStart > m.start) {
          const next = scope === 'this' ? cancelThisOccurrence(m, originalStart, now) : { ...m, recurrence: { ...m.recurrence, until: originalStart - 1 }, updatedAt: now };
          await database.events.put(next);
          await record('event', m.id, 'put', scope === 'this' ? 'occurrence-cancel' : 'series-end', { originalStart });
        } else {
          await database.events.delete(m.id);
          await record('event', m.id, 'delete', 'delete');
        }
      });
    },

    /** 複数日へコピー（既存の予定は変更しない） */
    async copyEventToDays(source: CalEvent, dayStarts: number[]) {
      return tx(async () => {
        const copies = copyToDays(source, dayStarts, newId, clock());
        for (const c of copies) {
          eventSchema.parse(c);
          await database.events.put(c);
          await record('event', c.id, 'put', 'copy', { from: source.id });
        }
        return copies.length;
      });
    },

    // ---------------- AR（自動開始・自動終了の予約） ----------------
    async setAutoReservation(id: string, r: { autoStartAt: number | null; autoEndAt: number | null }) {
      return tx(async () => {
        const t = await getTask(id);
        const next = { ...t, ...r, autoReserved: t.autoReserved || r.autoStartAt != null || r.autoEndAt != null, updatedAt: clock() };
        taskSchema.parse(next);
        await database.tasks.put(next);
        await record('task', id, 'put', 'auto-reserve', r);
        return next;
      });
    },

    /** 予約時刻を過ぎた AR を、予約した時刻の記録として反映する */
    async applyAutoReservations() {
      const now = clock();
      const due = await database.tasks.filter((t) => (t.autoStartAt != null && t.autoStartAt <= now) || (t.autoEndAt != null && t.autoEndAt <= now)).toArray();
      let n = 0;
      for (const t of due) {
        await tx(async () => {
          const cur = await getTask(t.id);
          for (const tr of applyAutoReservation(cur, now)) {
            await applyTransition(tr);
            n += 1;
          }
        });
      }
      return n;
    },

    // ---------------- 取り込み（TimeTree・ICS・テキスト） ----------------
    async importEvent(c: ImportCandidate, calendarId: string, sourceType: 'timetree' | 'ics' | 'text', updateId: string | null) {
      return tx(async () => {
        const now = clock();
        const source = { type: sourceType, externalId: c.externalId, fingerprint: c.fingerprint, owner: c.owner, calendarName: c.calendarName };
        if (updateId) {
          const cur = await database.events.get(updateId);
          if (!cur) throw new Error('更新する予定が見つかりません');
          const next = { ...cur, title: c.title, start: c.start, end: c.end, source, updatedAt: now };
          eventSchema.parse(next);
          await database.events.put(next);
          await record('event', next.id, 'put', 'import-update', { externalId: c.externalId });
          return next;
        }
        const ev = makeEvent({ title: c.title, calendarId, start: c.start, end: c.end, source }, now);
        eventSchema.parse(ev);
        await database.events.put(ev);
        await record('event', ev.id, 'put', 'import', { externalId: c.externalId });
        return ev;
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
