import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it } from 'vitest';
import { busyItems, HOUR, makeEvent, makeTask, parseInput, postponeOptions, startOfDay } from '@my-time/domain';
import { MyTimeDB } from './db';
import { createRepo, type CandidateToSave } from './repo';

const base = startOfDay(new Date(2026, 10, 15).getTime()) + 10 * HOUR;
let now = base;
let database: MyTimeDB;
let repo: ReturnType<typeof createRepo>;

beforeEach(async () => {
  database = new MyTimeDB(`plan-${Math.random()}`);
  repo = createRepo(database, () => now);
  now = base;
  await repo.ensureDefaults();
});

const toSave = (c: ReturnType<typeof parseInput> & { intent: 'create' }): CandidateToSave[] => c.candidates.map((x) => ({ entity: x.entity, spec: x.spec, title: x.title, start: x.start, end: x.end, allDay: !!x.details.__allDay, due: x.due, estimateMinutes: x.estimateMinutes, details: x.details, workplace: x.workplace, employerId: x.employerId, prep: x.prep, sessions: x.sessions }));

describe('提案の適用と取り消し（P04・P10・P30）', () => {
  it('延期を適用→取り消しで元の時刻に戻る。操作ログに変更前が残る', async () => {
    const t = makeTask({ title: '課題', plannedStart: base - 2 * HOUR, plannedEnd: base - HOUR }, now);
    await repo.saveTask(t, true);
    const p = postponeOptions(t, busyItems([], [t]), now)[0]!;
    const u = await repo.applyPlan(p);
    expect((await database.tasks.get(t.id))!.plannedStart).toBe(p.changes[0]!.after.start);
    const log = (await database.operationLog.toArray()).find((l) => l.action === 'plan');
    expect(log?.detail?.before).toEqual({ start: base - 2 * HOUR, end: base - HOUR });
    expect(await repo.revertPlan(u)).toEqual({ reverted: 1, skipped: 0 });
    expect((await database.tasks.get(t.id))!.plannedStart).toBe(base - 2 * HOUR);
  });
  it('別の操作で変わっていたら適用しない（誤上書きの防止）', async () => {
    const t = makeTask({ title: '課題', plannedStart: base, plannedEnd: base + HOUR }, now);
    await repo.saveTask(t, true);
    const p = postponeOptions(t, [], now)[1]!;
    await repo.moveTask(t.id, base + 3 * HOUR);
    await expect(repo.applyPlan(p)).rejects.toThrow('別の操作');
    expect((await database.tasks.get(t.id))!.plannedStart).toBe(base + 3 * HOUR);
  });
  it('作業枠（日時付きサブタスク）の追加と取り消し', async () => {
    const t = makeTask({ title: 'レポート', estimateMinutes: 120 }, now);
    await repo.saveTask(t, true);
    const u = await repo.applyPlan({ id: 'p', title: 'x', reason: '', changes: [], warnings: [], sessions: [{ taskId: t.id, title: '着手', start: base, end: base + HOUR }] });
    expect(await database.subtasks.where('taskId').equals(t.id).count()).toBe(1);
    await repo.revertPlan(u);
    expect(await database.subtasks.where('taskId').equals(t.id).count()).toBe(0);
  });
});

describe('文章からの登録（P01・S01）', () => {
  it('例A：勤務の予定・勤務先・準備タスクを1回で作り、取り消しで全部消える', async () => {
    const r = parseInput('土曜日はGU 18:30〜22:00、時給1,300円', { now, events: [], tasks: [] });
    if (r.intent !== 'create') throw new Error(r.intent);
    const made = await repo.createFromCandidates(toSave(r));
    const ev = (await database.events.get(made.events[0]!))!;
    expect(ev.calendarId).toBe('cal-job');
    expect(ev.extra?.spec).toMatchObject({ type: 'shift', details: { hourlyWage: 1300, workplace: 'GU' } });
    expect(ev.extra?.origin).toBe('text');
    expect((await database.employers.get(ev.employerId!))!.name).toBe('GU');
    const prep = await database.tasks.where('sourceEventId').equals(ev.id).toArray();
    expect(prep.map((t) => t.title)).toEqual(['出勤の準備']);
    await repo.undoCreated(made);
    expect(await database.events.count()).toBe(0);
    expect(await database.tasks.count()).toBe(0);
    expect(await database.employers.count()).toBe(0);
  });
  it('例B：課題は締切を保持し、作業枠をサブタスクとして作る', async () => {
    const r = parseInput('金曜までに経済学のレポート、2時間ぐらい', { now, events: [], tasks: [] });
    if (r.intent !== 'create') throw new Error(r.intent);
    const made = await repo.createFromCandidates(toSave(r));
    const t = (await database.tasks.get(made.tasks[0]!))!;
    expect(t.special).toBe('assignment');
    expect(t.assignment?.deadline).toBe(r.candidates[0]!.due);
    expect(t.plannedStart).toBeNull();
    expect((await database.subtasks.where('taskId').equals(t.id).sortBy('order')).map((s) => s.title)).toEqual(['着手', '見直し']);
  });
});

describe('種類の操作・履歴', () => {
  it('工程・準備は二重に作らない', async () => {
    const t = makeTask({ title: '論文', extra: { spec: { type: 'report', details: {} } } }, now);
    await repo.saveTask(t, true);
    expect(await repo.createSpecSteps(t.id)).toBe(5);
    expect(await repo.createSpecSteps(t.id)).toBe(0);
    const ev = makeEvent({ title: '外出', calendarId: 'cal-general', start: base + 7 * HOUR, end: base + 9 * HOUR, extra: { travelMinutes: 20, spec: { type: 'outing', details: { prepMinutes: 30 } } } }, now);
    await repo.saveEvent(ev, true);
    expect(await repo.createPrepTasks(ev.id)).toBe(2);
    expect(await repo.createPrepTasks(ev.id)).toBe(0);
    const prep = (await database.tasks.where('sourceEventId').equals(ev.id).toArray()).sort((a, b) => a.plannedStart! - b.plannedStart!);
    expect(prep.at(-1)!.plannedEnd).toBe(ev.start - 20 * 60_000);
  });
  it('S20：足りない材料だけで買い物を作る', async () => {
    const t = makeTask({ title: 'カレー', extra: { spec: { type: 'cooking', details: { ingredients: [{ id: '1', name: '玉ねぎ', done: true }, { id: '2', name: 'ルー', done: false }] } } } }, now);
    await repo.saveTask(t, true);
    const s = await repo.shoppingFromCooking(t.id);
    expect((s.extra?.spec?.details.items as { name: string }[]).map((x) => x.name)).toEqual(['ルー']);
    await expect(repo.shoppingFromCooking(t.id)).rejects.toThrow('もう作って');
  });
  it('P48：削除したタスクを履歴から復元できる（サブタスクも）', async () => {
    const t = makeTask({ title: '消すタスク' }, now);
    await repo.saveTask(t, true);
    await repo.addSubtask(t.id, '子');
    await repo.deleteTask(t.id);
    const log = (await database.operationLog.toArray()).find((l) => l.action === 'delete' && l.entityId === t.id)!;
    await repo.rollback(log.seq!);
    expect((await database.tasks.get(t.id))?.title).toBe('消すタスク');
    expect(await database.subtasks.where('taskId').equals(t.id).count()).toBe(1);
  });
  it('S19：繰り返しタスクは完了の取り消し→再完了でも次の回を二重に作らない', async () => {
    const t = makeTask({ title: '掃除', plannedStart: base, plannedEnd: base + HOUR, repeat: { freq: 'weekly', interval: 1 } }, now);
    await repo.saveTask(t, true);
    await repo.taskAction(t.id, 'start');
    await repo.taskAction(t.id, 'finish');
    await repo.taskAction(t.id, 'undoFinish');
    await repo.taskAction(t.id, 'finish');
    expect(await database.tasks.filter((x) => x.title === '掃除').count()).toBe(2);
  });
});
