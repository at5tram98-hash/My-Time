import {
  defaultDetails, makeEmployer, makeTask, normalizeEvent, normalizeTask, parseOccurrenceId, prepBefore, specOf, SPEC_BY_ID,
  type Change, type Proposal, type SpecTypeId,
  startOfDay, addDays, addMonths, applyAutoReservation, applyTaskAction, canAddSubtask, cancelThisOccurrence, convertKind, copyToDays, defaultCalendars,
  editThisOccurrence, makeEvent, makeSubtask, newId, planClassTasks, recordManualProgress, splitFromOccurrence, toggleCheck, toggleSubtask,
  type CalEvent, type Calendar, type Employer, type ImportCandidate, type Subject, type Subtask, type Task, type TaskAction, type TaskKind, type TaskTransition,
} from '@my-time/domain';
import { calendarSchema, categorySchema, employerSchema, eventSchema, studioTypeSchema, subjectSchema, subtaskSchema, taskSchema } from '@my-time/contracts';
import type { StudioType, Subtask as SubtaskT, TaskCategory } from '@my-time/domain';
/** 提案を適用したときの取り消し用の記録 */
export interface PlanUndo { proposalId: string; title: string; changes: Change[]; createdSubtasks: string[] }
/** 文章からの登録で作ったもの（直後の取り消し用） */
export interface CreatedSet { events: string[]; tasks: string[]; subtasks: string[]; employers: string[] }
/** 確認画面で選んだ候補（nlparse の Candidate から、採用した準備・作業枠だけを残したもの） */
export interface CandidateToSave {
  entity: 'event' | 'task';
  spec: SpecTypeId | null;
  title: string;
  start: number | null;
  end: number | null;
  allDay: boolean;
  due: number | null;
  estimateMinutes: number | null;
  details: Record<string, unknown>;
  workplace: string | null;
  employerId: string | null;
  prep: { title: string; start: number; end: number }[];
  sessions: { title: string; start: number; end: number }[];
}

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
    database.transaction('rw', [database.tasks, database.events, database.subtasks, database.calendars, database.subjects, database.employers, database.categories, database.studioTypes, database.operationLog, database.outbox, database.settings], fn);

  /** 繰り返しタスクを完了したら次の回を作る（Reminders と同じ考え方） */
  const nextRepeat = async (t: Task, now: number) => {
    if (!t.repeat || (t.status !== 'done' && !t.checked)) return;
    // 完了の取り消し→再完了などで同じ回から次の回を二重に作らない（S19）
    const key = `repeat:${t.id}`;
    if ((await database.tasks.where('sourceKey').equals(key).count()) > 0) return;
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
      sourceKey: key,
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
        const prev = isNew ? undefined : await database.tasks.get(t.id);
        await database.tasks.put(t);
        await record('task', t.id, 'put', isNew ? 'create' : 'update', prev ? { snapshot: prev } : undefined);
        return t;
      });
    },

    async deleteTask(id: string) {
      return tx(async () => {
        const prev = await database.tasks.get(id);
        const subRows = await database.subtasks.where('taskId').equals(id).toArray();
        await database.subtasks.bulkDelete(subRows.map((x) => x.id));
        await database.tasks.delete(id);
        await record('task', id, 'delete', 'delete', { subtasks: subRows.length, ...(prev ? { snapshot: prev, subtasksSnapshot: subRows } : {}) });
      });
    },

    async copyTaskToDay(id: string, day: number) {
      return tx(async () => {
        const t = await getTask(id);
        const now = clock();
        const anchor = t.plannedStart ?? t.checkAt ?? now;
        const shift = (v: number | null | undefined) => v == null ? null : addDays(v, Math.round((startOfDay(day) - startOfDay(anchor)) / 86400000));
        const next: Task = { ...t, id: newId(), status: 'notStarted', intervals: [], actualStart: null, actualEnd: null, manualProgress: null, pausedEver: false, checked: false, checkedAt: null, autoReserved: false, autoStartAt: null, autoEndAt: null, sourceEventId: null, sourceKey: null, eventId: null, repeat: null, assignment: t.assignment ? { ...t.assignment, deadline: shift(t.assignment.deadline) } : null, testPrep: t.testPrep ? { ...t.testPrep, examAt: shift(t.testPrep.examAt) } : null, plannedStart: shift(t.plannedStart), plannedEnd: shift(t.plannedEnd), checkAt: shift(t.checkAt), createdAt: now, updatedAt: now };
        taskSchema.parse(next);
        await database.tasks.add(next);
        await record('task', next.id, 'put', 'copy', { from: id });
        for (const old of await database.subtasks.where('taskId').equals(id).toArray()) {
          const sub = { ...old, id: newId(), taskId: next.id, done: false, completedAt: null, plannedStart: shift(old.plannedStart), plannedEnd: shift(old.plannedEnd), createdAt: now, updatedAt: now };
          subtaskSchema.parse(sub);
          await database.subtasks.add(sub);
          await record('subtask', sub.id, 'put', 'copy', { from: old.id });
        }
        return next;
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

    /** Studio の数値項目を進捗パネルから更新（C26）。manualProgress には書かない */
    async setStudioValue(id: string, fieldId: string, value: number | null) {
      return tx(async () => {
        const t = await getTask(id);
        const st = t.extra?.studio;
        if (!st) throw new Error('専用の項目がありません');
        const next: Task = { ...t, extra: { ...t.extra, studio: { ...st, values: { ...st.values, [fieldId]: value } } }, updatedAt: clock() };
        await database.tasks.put(next);
        await record('task', id, 'put', 'progress', { studioField: fieldId, value });
        return next;
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
        const prev = isNew ? undefined : await database.events.get(e.id);
        await database.events.put(e);
        await record('event', e.id, 'put', isNew ? 'create' : 'update', prev ? { snapshot: prev } : undefined);
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
        await record('event', id, 'put', 'move', { from: e.start, to: newStart, snapshot: e });
        return n;
      });
    },

    async moveTask(id: string, newStart: number) {
      return tx(async () => {
        const t = await getTask(id);
        if (t.plannedStart == null || t.plannedEnd == null) throw new Error('予定時刻がありません');
        const n = { ...t, plannedStart: newStart, plannedEnd: newStart + (t.plannedEnd - t.plannedStart), updatedAt: clock() };
        await database.tasks.put(n);
        await record('task', id, 'put', 'move', { from: t.plannedStart, to: newStart, snapshot: t });
        return n;
      });
    },

    async deleteEvent(id: string) {
      return tx(async () => {
        const prev = await database.events.get(id);
        await database.events.delete(id);
        await record('event', id, 'delete', 'delete', prev ? { snapshot: prev } : undefined);
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

    // ---- UI/UX v2：カテゴリー（Q55）----
    async saveCategory(c: TaskCategory, isNew: boolean) {
      const v = { ...c, updatedAt: clock() };
      categorySchema.parse(v);
      return tx(async () => {
        await database.categories.put(v);
        await record('category', v.id, 'put', isNew ? 'create' : 'update');
        return v;
      });
    },
    /** カテゴリーを消しても、タスクに入っているカテゴリー名は残す（データを書き換えない） */
    async deleteCategory(id: string) {
      return tx(async () => {
        await database.categories.delete(id);
        await record('category', id, 'delete', 'delete');
      });
    },
    async reorderCategories(ids: string[]) {
      return tx(async () => {
        const now = clock();
        for (const [i, id] of ids.entries()) {
          const c = await database.categories.get(id);
          if (c && c.order !== i) {
            await database.categories.put({ ...c, order: i, updatedAt: now });
            await record('category', id, 'put', 'reorder');
          }
        }
      });
    },
    // ---- Create Studio（Q82〜91）：定義の保存は版を上げ、旧版は変更履歴に残す ----
    async saveStudioType(t: StudioType, isNew: boolean) {
      return tx(async () => {
        const prev = isNew ? undefined : await database.studioTypes.get(t.id);
        const now = clock();
        let v: StudioType = { ...t, updatedAt: now };
        if (prev && JSON.stringify({ s: prev.sections, f: prev.fields, p: prev.progress }) !== JSON.stringify({ s: t.sections, f: t.fields, p: t.progress })) {
          v = { ...v, version: prev.version + 1, revisions: [...prev.revisions, { version: prev.version, at: now, definition: { sections: prev.sections, fields: prev.fields, progress: prev.progress } }].slice(-50) };
        }
        studioTypeSchema.parse(v);
        await database.studioTypes.put(v);
        await record('studioType', v.id, 'put', isNew ? 'create' : 'update', { version: v.version });
        return v;
      });
    },
    /** 種類の削除は種類の定義だけ。既存の予定・タスクと入力済みの値は消さない（Q91） */
    async deleteStudioType(id: string) {
      return tx(async () => {
        await database.studioTypes.delete(id);
        await record('studioType', id, 'delete', 'delete');
      });
    },
    // ---- サブタスク（Q37）----
    async renameSubtask(id: string, title: string) {
      return tx(async () => {
        const s0 = await database.subtasks.get(id);
        if (!s0) return;
        const v: SubtaskT = { ...s0, title: title.trim() || s0.title, updatedAt: clock() };
        subtaskSchema.parse(v);
        await database.subtasks.put(v);
        await record('subtask', id, 'put', 'update');
      });
    },
    /** サブタスクの日時・見積（C07）。終了だけ・終了が開始以前・負や不正な見積は保存しない */
    async setSubtaskTime(id: string, t: { plannedStart: number | null; plannedEnd: number | null; estimateMinutes: number | null }) {
      if (t.plannedEnd != null && t.plannedStart == null) throw new Error('終了だけは設定できません。開始も入力してください');
      if (t.plannedStart != null && t.plannedEnd != null && t.plannedEnd <= t.plannedStart) throw new Error('終了は開始より後にしてください');
      if (t.estimateMinutes != null && !(Number.isFinite(t.estimateMinutes) && t.estimateMinutes > 0)) throw new Error('見積は1分以上の数で入力してください');
      for (const v of [t.plannedStart, t.plannedEnd]) if (v != null && !Number.isFinite(v)) throw new Error('日時が正しくありません');
      return tx(async () => {
        const s0 = await database.subtasks.get(id);
        if (!s0) throw new Error('サブタスクが見つかりません');
        const v: SubtaskT = { ...s0, plannedStart: t.plannedStart, plannedEnd: t.plannedEnd, estimateMinutes: t.estimateMinutes, updatedAt: clock() };
        subtaskSchema.parse(v);
        await database.subtasks.put(v);
        await record('subtask', id, 'put', 'update', { taskId: s0.taskId, time: true });
        return v;
      });
    },
    /** 親の日時を変えたとき、子の日時を同じ差分だけ動かす（ユーザーが明示的に選んだときだけ：C07） */
    async shiftSubtaskTimes(taskId: string, delta: number) {
      if (!delta) return;
      return tx(async () => {
        const now = clock();
        for (const st of await database.subtasks.where('taskId').equals(taskId).toArray()) {
          if (st.plannedStart == null) continue;
          const v: SubtaskT = { ...st, plannedStart: st.plannedStart + delta, plannedEnd: st.plannedEnd != null ? st.plannedEnd + delta : st.plannedEnd ?? null, updatedAt: now };
          await database.subtasks.put(v);
          await record('subtask', st.id, 'put', 'move', { taskId, delta });
        }
      });
    },
    async reorderSubtasks(ids: string[]) {
      return tx(async () => {
        const now = clock();
        for (const [i, id] of ids.entries()) {
          const st = await database.subtasks.get(id);
          if (st && st.order !== i) {
            await database.subtasks.put({ ...st, order: i, updatedAt: now });
            await record('subtask', id, 'put', 'reorder');
          }
        }
      });
    },
    // ---- 編集の下書き（端末内だけ：Q81・Q90）----
    async saveDraft(key: string, data: Record<string, unknown>) {
      await database.drafts.put({ key, at: clock(), data });
    },
    async getDraft(key: string) {
      return database.drafts.get(key);
    },
    async clearDraft(key: string) {
      await database.drafts.delete(key);
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

    // ---------------- 計画の提案を適用・取り消し（P04・P05・P10・P29・P30） ----------------
    /**
     * 提案（変更前→変更後の差分）を1トランザクションで適用する。
     * 適用前に「変更前」の値が今の値と一致するか確かめ、別の操作で変わっていたら何も変えずに止める。
     * 戻すための記録（PlanUndo）を返し、操作ログにも変更前の値を残す。
     */
    async applyPlan(p: Proposal): Promise<PlanUndo> {
      return tx(async () => {
        const now = clock();
        const applied: Change[] = [];
        const created: string[] = [];
        for (const c of p.changes) {
          if (c.entity === 'task') {
            const t = await getTask(c.id);
            if (t.plannedStart !== c.before.start || t.plannedEnd !== c.before.end) throw new Error(`「${t.title}」は別の操作で変わったため、提案を適用しませんでした`);
            const n: Task = { ...t, plannedStart: c.after.start, plannedEnd: c.after.end, updatedAt: now };
            taskSchema.parse(n);
            await database.tasks.put(n);
            await record('task', t.id, 'put', 'plan', { proposal: p.id, before: c.before, after: c.after });
          } else if (c.entity === 'subtask') {
            const s0 = await database.subtasks.get(c.id);
            if (!s0) throw new Error('作業枠が見つかりません');
            await database.subtasks.put({ ...s0, plannedStart: c.after.start, plannedEnd: c.after.end, updatedAt: now });
            await record('subtask', s0.id, 'put', 'plan', { proposal: p.id, before: c.before, after: c.after });
          } else {
            const occ = parseOccurrenceId(c.id);
            const m = await database.events.get(occ?.masterId ?? c.id);
            if (!m) throw new Error('予定が見つかりません');
            if (occ && m.recurrence) {
              const next = editThisOccurrence(m, occ.originalStart, { start: c.after.start!, end: c.after.end! }, now);
              await database.events.put(next);
              await record('event', m.id, 'put', 'plan', { proposal: p.id, originalStart: occ.originalStart, before: c.before, after: c.after, masterBefore: m });
            } else {
              if (m.start !== c.before.start || m.end !== c.before.end) throw new Error(`「${m.title}」は別の操作で変わったため、提案を適用しませんでした`);
              await database.events.put({ ...m, start: c.after.start!, end: c.after.end!, updatedAt: now });
              await record('event', m.id, 'put', 'plan', { proposal: p.id, before: c.before, after: c.after });
            }
          }
          applied.push(c);
        }
        for (const [i, s] of (p.sessions ?? []).entries()) {
          const task = await getTask(s.taskId);
          if (!canAddSubtask(task)) throw new Error('このタスクには作業枠（サブタスク）を追加できません');
          const order = (await database.subtasks.where('taskId').equals(task.id).count()) + i;
          const sub = { ...makeSubtask(task.id, s.title, order, now), plannedStart: s.start, plannedEnd: s.end, estimateMinutes: Math.round((s.end - s.start) / 60_000) };
          subtaskSchema.parse(sub);
          await database.subtasks.add(sub);
          await record('subtask', sub.id, 'put', 'plan-create', { proposal: p.id, taskId: task.id });
          created.push(sub.id);
        }
        return { proposalId: p.id, title: p.title, changes: applied, createdSubtasks: created };
      });
    },

    /** applyPlan の取り消し。適用後にさらに変えられた項目は上書きせず、件数を返す */
    async revertPlan(u: PlanUndo): Promise<{ reverted: number; skipped: number }> {
      return tx(async () => {
        const now = clock();
        let reverted = 0;
        let skipped = 0;
        for (const c of [...u.changes].reverse()) {
          if (c.entity === 'task') {
            const t = await database.tasks.get(c.id);
            if (!t || t.plannedStart !== c.after.start || t.plannedEnd !== c.after.end) { skipped += 1; continue; }
            await database.tasks.put({ ...t, plannedStart: c.before.start, plannedEnd: c.before.end, updatedAt: now });
            await record('task', t.id, 'put', 'plan-undo', { proposal: u.proposalId });
          } else if (c.entity === 'subtask') {
            const s0 = await database.subtasks.get(c.id);
            if (!s0) { skipped += 1; continue; }
            await database.subtasks.put({ ...s0, plannedStart: c.before.start, plannedEnd: c.before.end, updatedAt: now });
            await record('subtask', s0.id, 'put', 'plan-undo', { proposal: u.proposalId });
          } else {
            const occ = parseOccurrenceId(c.id);
            const m = await database.events.get(occ?.masterId ?? c.id);
            if (!m) { skipped += 1; continue; }
            if (occ && m.recurrence) {
              await database.events.put({ ...m, exceptions: m.exceptions.filter((x) => !(x.originalStart === occ.originalStart && x.kind === 'override' && x.start === c.after.start)), updatedAt: now });
            } else {
              if (m.start !== c.after.start || m.end !== c.after.end) { skipped += 1; continue; }
              await database.events.put({ ...m, start: c.before.start!, end: c.before.end!, updatedAt: now });
            }
            await record('event', m.id, 'put', 'plan-undo', { proposal: u.proposalId });
          }
          reverted += 1;
        }
        for (const id of u.createdSubtasks) {
          if (!(await database.subtasks.get(id))) continue;
          await database.subtasks.delete(id);
          await record('subtask', id, 'delete', 'plan-undo', { proposal: u.proposalId });
          reverted += 1;
        }
        return { reverted, skipped };
      });
    },

    // ---------------- 文章からの登録（P01） ----------------
    /**
     * 確認画面で選んだ候補を作る。勤務先が未登録なら作る。準備・作業枠もつなげて作る。
     * すべて1トランザクション。作ったものの ID を返す（直後に取り消せる）。
     */
    async createFromCandidates(items: CandidateToSave[]): Promise<CreatedSet> {
      return tx(async () => {
        const now = clock();
        const made: CreatedSet = { events: [], tasks: [], subtasks: [], employers: [] };
        const cals = await database.calendars.orderBy('order').toArray();
        const jobCal = cals.find((c) => c.kind === 'job');
        const classCal = cals.find((c) => c.kind === 'class');
        const generalCal = cals.find((c) => c.kind === 'general') ?? cals[0];
        if (!generalCal) throw new Error('カレンダーがありません');
        for (const c of items) {
          const spec = c.spec ? { type: c.spec, details: { ...defaultDetails(c.spec), ...c.details } } : null;
          if (spec) delete (spec.details as Record<string, unknown>).__allDay;
          const extra = { origin: 'text' as const, ...(spec ? { spec } : {}), ...(c.allDay ? { allDay: true } : {}) };
          if (c.entity === 'event' && c.start != null && c.end != null) {
            let employerId = c.employerId;
            if (c.spec === 'shift' && !employerId && c.workplace) {
              const existing = await database.employers.filter((e) => e.name.toLowerCase() === c.workplace!.toLowerCase()).first();
              if (existing) employerId = existing.id;
              else {
                const settings = await database.settings.get('app');
                const emp = makeEmployer(c.workplace.slice(0, 100), now, settings?.defaultJobReminderHours ?? 2);
                employerSchema.parse(emp);
                await database.employers.put(emp);
                await record('employer', emp.id, 'put', 'create', { origin: 'text' });
                made.employers.push(emp.id);
                employerId = emp.id;
              }
            }
            const calendarId = c.spec === 'shift' ? jobCal?.id ?? generalCal.id : c.spec === 'class' ? classCal?.id ?? generalCal.id : generalCal.id;
            const ev = makeEvent({ title: c.title, calendarId, start: c.start, end: c.end, employerId: calendarId === jobCal?.id ? employerId : null, extra }, now);
            eventSchema.parse(ev);
            await database.events.put(ev);
            await record('event', ev.id, 'put', 'create', { origin: 'text' });
            made.events.push(ev.id);
            for (const [i, p] of c.prep.entries()) {
              const t = makeTask({ title: p.title, plannedStart: p.start, plannedEnd: p.end, sourceEventId: ev.id, sourceKey: `spec:${ev.id}:prep:${i}`, icon: 'person', extra: { origin: 'text', spec: { type: 'routine', details: { forEvent: ev.id, private: true } } } }, now);
              taskSchema.parse(t);
              await database.tasks.put(t);
              await record('task', t.id, 'put', 'create', { origin: 'text', sourceEventId: ev.id });
              made.tasks.push(t.id);
            }
          } else {
            const def = c.spec ? SPEC_BY_ID[c.spec] : null;
            const kind = def?.taskKind ?? 'do';
            const details = spec?.details ?? {};
            if (c.due != null && spec && !('dueAt' in details) && !('examAt' in details)) (details as Record<string, unknown>).dueAt = c.due;
            const base: Partial<Task> & Pick<Task, 'title'> = {
              title: c.title, kind, estimateMinutes: c.estimateMinutes, icon: def?.icon ?? 'circle',
              ...(kind === 'do' ? { plannedStart: c.start, plannedEnd: c.end } : { checkAt: c.start ?? c.due }),
              ...(c.spec === 'assignment' ? { special: 'assignment', assignment: { content: '', submitMethod: '', submitTo: '', deadline: c.due } } : {}),
              ...(c.spec === 'exam' ? { special: 'testPrep', testPrep: { examAt: c.due, subjectId: null, subjectName: '' } } : {}),
              extra: { ...extra, ...(spec ? { spec: { type: spec.type, details } } : {}) },
            };
            const t = makeTask(base, now);
            taskSchema.parse(t);
            await database.tasks.put(t);
            await record('task', t.id, 'put', 'create', { origin: 'text' });
            made.tasks.push(t.id);
            for (const [i, s] of c.sessions.entries()) {
              const sub = { ...makeSubtask(t.id, s.title, i, now), plannedStart: s.start, plannedEnd: s.end, estimateMinutes: Math.round((s.end - s.start) / 60_000) };
              subtaskSchema.parse(sub);
              await database.subtasks.add(sub);
              await record('subtask', sub.id, 'put', 'create', { origin: 'text', taskId: t.id });
              made.subtasks.push(sub.id);
            }
          }
        }
        return made;
      });
    },

    /** createFromCandidates の取り消し（作った直後だけ使う。作られたものを削除する） */
    async undoCreated(m: CreatedSet) {
      return tx(async () => {
        for (const id of m.subtasks) { if (await database.subtasks.get(id)) { await database.subtasks.delete(id); await record('subtask', id, 'delete', 'undo-create'); } }
        for (const id of m.tasks) {
          if (!(await database.tasks.get(id))) continue;
          const subs = await database.subtasks.where('taskId').equals(id).primaryKeys();
          await database.subtasks.bulkDelete(subs);
          await database.tasks.delete(id);
          await record('task', id, 'delete', 'undo-create');
        }
        for (const id of m.events) { if (await database.events.get(id)) { await database.events.delete(id); await record('event', id, 'delete', 'undo-create'); } }
        for (const id of m.employers) {
          if ((await database.events.filter((e) => e.employerId === id).count()) > 0) continue;
          if (await database.employers.get(id)) { await database.employers.delete(id); await record('employer', id, 'delete', 'undo-create'); }
        }
      });
    },

    // ---------------- 専門の種類 ----------------
    /** 種類の詳細だけを更新（情報カードのチェック・入金確認など） */
    async updateSpecDetails(entity: 'task' | 'event', id: string, patch: Record<string, unknown>) {
      return tx(async () => {
        const now = clock();
        if (entity === 'task') {
          const t = await getTask(id);
          const cur = specOf(t);
          if (!cur) throw new Error('種類が設定されていません');
          const n: Task = { ...t, extra: { ...t.extra, spec: { type: cur.type, details: { ...cur.details, ...patch } } }, updatedAt: now };
          taskSchema.parse(n);
          await database.tasks.put(n);
          await record('task', id, 'put', 'spec', { keys: Object.keys(patch), before: cur.details });
          return;
        }
        const e = await database.events.get(id);
        if (!e) throw new Error('予定が見つかりません');
        const cal = await database.calendars.get(e.calendarId);
        const cur = specOf(e, cal?.kind);
        if (!cur) throw new Error('種類が設定されていません');
        const n: CalEvent = { ...e, extra: { ...e.extra, spec: { type: cur.type, details: { ...cur.details, ...patch } } }, updatedAt: now };
        eventSchema.parse(n);
        await database.events.put(n);
        await record('event', id, 'put', 'spec', { keys: Object.keys(patch), before: cur.details });
      });
    },

    /** 種類の工程をサブタスクとして作る（同じ名前の工程は作らない） */
    async createSpecSteps(taskId: string) {
      return tx(async () => {
        const t = await getTask(taskId);
        const sp = specOf(t);
        const def = sp ? SPEC_BY_ID[sp.type] : null;
        const custom = sp?.type === 'routine' && Array.isArray(sp.details.steps) ? (sp.details.steps as { title: string; minutes: number }[]) : null;
        const list = custom ?? def?.steps ?? [];
        if (!list.length) throw new Error('この種類には工程がありません');
        if (!canAddSubtask(t)) throw new Error('このタスクにはサブタスクを追加できません');
        const existing = await database.subtasks.where('taskId').equals(taskId).toArray();
        const have = new Set(existing.map((s) => s.title));
        let order = existing.length;
        let n = 0;
        for (const st of list) {
          if (have.has(st.title)) continue;
          const sub = { ...makeSubtask(taskId, st.title, order++, clock()), estimateMinutes: st.minutes > 0 ? st.minutes : null };
          subtaskSchema.parse(sub);
          await database.subtasks.add(sub);
          await record('subtask', sub.id, 'put', 'create', { taskId, from: 'spec-steps' });
          n += 1;
        }
        return n;
      });
    },

    /** 予定の準備タスクを作る（S01・S10・S14〜S16）。同じ予定から二重に作らない */
    async createPrepTasks(eventId: string) {
      return tx(async () => {
        const e = await database.events.get(eventId);
        if (!e) throw new Error('予定が見つかりません');
        const cal = await database.calendars.get(e.calendarId);
        const sp = specOf(e, cal?.kind);
        const def = sp ? SPEC_BY_ID[sp.type] : null;
        if (!def?.prep?.length) throw new Error('この種類には準備がありません');
        const now = clock();
        const existing = new Set((await database.tasks.where('sourceEventId').equals(eventId).toArray()).map((t) => t.sourceKey));
        const before = def.prep.filter((p) => p.place === 'before');
        const placed = prepBefore(e.start, e.extra?.travelMinutes ?? null, before.map((p) => ({ title: p.title, minutes: sp?.type === 'outing' && p.title === '髪・身支度' ? Number(sp.details.prepMinutes ?? p.minutes) : p.minutes })));
        let n = 0;
        for (const [i, p] of def.prep.entries()) {
          const key = `spec:${eventId}:prep:${i}`;
          if (existing.has(key)) continue;
          const slot = p.place === 'before' ? placed.find((x) => x.title === p.title) : null;
          const t = makeTask({
            title: p.title, sourceEventId: eventId, sourceKey: key, estimateMinutes: p.minutes, icon: def.icon,
            plannedStart: slot?.start ?? null, plannedEnd: slot?.end ?? null,
            extra: { origin: 'plan', spec: { type: p.place === 'before' ? 'routine' : sp!.type === 'presentation' ? 'assignment' : 'chores', details: { forEvent: eventId, dueAt: e.start, private: sp!.type === 'outing' } } },
          }, now);
          taskSchema.parse(t);
          await database.tasks.put(t);
          await record('task', t.id, 'put', 'create', { sourceEventId: eventId, from: 'spec-prep' });
          n += 1;
        }
        return n;
      });
    },

    /** S20：足りない材料だけで買い物タスクを作る（同じ料理から二重に作らない） */
    async shoppingFromCooking(taskId: string) {
      return tx(async () => {
        const t = await getTask(taskId);
        const sp = specOf(t);
        const missing = (Array.isArray(sp?.details.ingredients) ? (sp!.details.ingredients as { id: string; name: string; done: boolean }[]) : []).filter((x) => !x.done);
        if (!missing.length) throw new Error('足りない材料はありません');
        const key = `cook:${taskId}`;
        if ((await database.tasks.where('sourceKey').equals(key).count()) > 0) throw new Error('この料理の買い物はもう作ってあります');
        const now = clock();
        const end = t.plannedStart;
        const s = makeTask({ title: `${t.title}の買い物`, sourceKey: key, icon: 'cart', estimateMinutes: 30, plannedStart: end != null ? end - 60 * 60_000 : null, plannedEnd: end != null ? end - 30 * 60_000 : null, extra: { origin: 'plan', spec: { type: 'shopping', details: { items: missing.map((x) => ({ ...x, done: false })) } } } }, now);
        taskSchema.parse(s);
        await database.tasks.put(s);
        await record('task', s.id, 'put', 'create', { from: 'cooking', taskId });
        return s;
      });
    },

    // ---------------- 変更履歴と巻き戻し（P48） ----------------
    /** 操作ログの1件を、記録した変更前の内容へ戻す（変更前の内容を記録した操作だけ） */
    async rollback(seq: number) {
      return tx(async () => {
        const log = await database.operationLog.get(seq);
        const before = log?.detail?.snapshot as Record<string, unknown> | undefined;
        if (!log || !before) throw new Error('この操作は戻せません');
        const now = clock();
        if (log.entity === 'task') {
          const n = normalizeTask({ ...(before as unknown as Task), updatedAt: now });
          taskSchema.parse(n);
          await database.tasks.put(n);
          for (const s of (log.detail?.subtasksSnapshot as Subtask[] | undefined) ?? []) if (!(await database.subtasks.get(s.id))) { await database.subtasks.put(s); await record('subtask', s.id, 'put', 'rollback'); }
          await record('task', n.id, 'put', 'rollback', { seq, snapshot: (await database.tasks.get(n.id)) ?? null });
          return n.title;
        }
        if (log.entity === 'event') {
          const n = normalizeEvent({ ...(before as unknown as CalEvent), updatedAt: now });
          eventSchema.parse(n);
          await database.events.put(n);
          await record('event', n.id, 'put', 'rollback', { seq });
          return n.title;
        }
        throw new Error('この操作は戻せません');
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
