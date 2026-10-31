import 'fake-indexeddb/auto';
import { beforeEach, describe, expect, it } from 'vitest';
import { HOUR, makeEvent, makeTask, startOfDay } from '@my-time/domain';
import { MyTimeDB } from './db';
import { createRepo } from './repo';

const base = startOfDay(new Date(2026, 9, 12).getTime()) + 10 * HOUR;
let now = base;
let database: MyTimeDB;
let repo: ReturnType<typeof createRepo>;

beforeEach(async () => {
  database = new MyTimeDB(`test-${Math.random()}`);
  repo = createRepo(database, () => now);
  now = base;
  await repo.ensureDefaults();
});

describe('ローカル永続化', () => {
  it('既定カレンダーは一度だけ作られ、既存データを上書きしない', async () => {
    await database.calendars.update('cal-general', { name: '自分用' });
    await repo.ensureDefaults();
    expect(await database.calendars.count()).toBe(3);
    expect((await database.calendars.get('cal-general'))?.name).toBe('自分用');
  });

  it('タスク作成→編集→別インスタンスで再読込しても残る', async () => {
    const t = makeTask({ title: '課題', plannedStart: base, plannedEnd: base + HOUR }, now);
    await repo.saveTask(t, true);
    await repo.saveTask({ ...t, title: '課題（改）' }, false);
    database.close();
    const reopened = new MyTimeDB(database.name);
    expect((await reopened.tasks.get(t.id))?.title).toBe('課題（改）');
    expect(await reopened.outbox.count()).toBe(2);
  });

  it('開始→完了→取り消しが操作ログに残り、実績が整合する', async () => {
    const t = makeTask({ title: 'x', plannedStart: base, plannedEnd: base + HOUR }, now);
    await repo.saveTask(t, true);
    await repo.taskAction(t.id, 'start');
    now += HOUR / 2;
    await repo.taskAction(t.id, 'finish');
    now += HOUR / 4;
    const u = await repo.taskAction(t.id, 'undoFinish');
    expect(u.status).toBe('paused');
    expect(u.actualEnd).toBeNull();
    const actions = (await database.operationLog.orderBy('seq').toArray()).map((l) => l.action);
    expect(actions).toEqual(['create', 'start', 'finish', 'undoFinish']);
  });

  it('100%確認後の完了は未開始タスクでも一貫した実績を作る', async () => {
    const t = makeTask({ title: 'x', plannedStart: base, plannedEnd: base + HOUR }, now);
    await repo.saveTask(t, true);
    const done = await repo.completeFromProgress(t.id);
    expect(done).toMatchObject({ status: 'done', manualProgress: { value: 1 } });
    expect(done.actualEnd).not.toBeNull();
  });

  it('予定に内包されるタスクにはサブタスクを追加できない', async () => {
    const t = makeTask({ title: 'x', eventId: 'ev1' }, now);
    await repo.saveTask(t, true);
    await expect(repo.addSubtask(t.id, 'a')).rejects.toThrow();
    expect(await database.subtasks.count()).toBe(0);
  });

  it('サブタスクを持つ親の手動進捗は拒否', async () => {
    const t = makeTask({ title: 'x' }, now);
    await repo.saveTask(t, true);
    await repo.addSubtask(t.id, 'a');
    await expect(repo.recordProgress(t.id, 0.5)).rejects.toThrow();
  });

  it('予定のドラッグ移動は長さを保持', async () => {
    const e = makeEvent({ title: '授業', calendarId: 'cal-class', start: base, end: base + 90 * 60_000 }, now);
    await repo.saveEvent(e, true);
    const m = await repo.moveEvent(e.id, base + HOUR);
    expect(m.end - m.start).toBe(90 * 60_000);
  });

  it('不正な時間（終了<=開始）は保存しない', async () => {
    const t = makeTask({ title: 'x', plannedStart: base, plannedEnd: base }, now);
    await expect(repo.saveTask(t, true)).rejects.toThrow();
    expect(await database.tasks.count()).toBe(0);
  });

  it('タスク削除でサブタスクも消え、削除がログに残る', async () => {
    const t = makeTask({ title: 'x' }, now);
    await repo.saveTask(t, true);
    await repo.addSubtask(t.id, 'a');
    await repo.deleteTask(t.id);
    expect(await database.subtasks.count()).toBe(0);
    expect((await database.operationLog.toArray()).some((l) => l.action === 'delete')).toBe(true);
  });
});
