import 'fake-indexeddb/auto';
import Dexie from 'dexie';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { makeTask, type Task } from '@my-time/domain';
import type { PullChange, PushResult, SyncOp } from '@my-time/contracts';
import { MyTimeDB } from '../data/db';
import { createRepo } from '../data/repo';
import { ApiError, type Api } from './api';
import { SyncEngine } from './engine';

/** サーバーの冪等・版管理を最小限に再現した模擬 */
function fakeServer() {
  const rows = new Map<string, { version: number; data: Record<string, unknown> | null; deleted: boolean; seq: number; reason: PullChange['reason']; restored: string | null }>();
  const receipts = new Map<string, number>();
  let seq = 0;
  const applied: string[] = [];
  const s = {
    rows,
    applied,
    failNext: 0 as number,
    /** サーバーは反映したが応答が届かなかった（通信断）を再現 */
    dropResponseOnce: false,
    push: vi.fn(async (ops: SyncOp[]): Promise<PushResult> => {
      if (s.failNext > 0) {
        s.failNext -= 1;
        throw new ApiError('オフラインです', 0);
      }
      const results = ops.map((op) => {
        const done = receipts.get(op.opId);
        if (done != null) return { opId: op.opId, status: 'duplicate' as const, version: done };
        const k = `${op.entity}:${op.entityId}`;
        const cur = rows.get(k);
        if ((cur?.version ?? 0) !== op.baseVersion && cur && ((cur.data?.updatedAt as number) ?? 0) > op.clientUpdatedAt) {
          return { opId: op.opId, status: 'conflict' as const, version: cur.version, serverRecord: cur.data };
        }
        const v = (cur?.version ?? 0) + 1;
        rows.set(k, { version: v, data: op.op === 'put' ? op.record : null, deleted: op.op === 'delete', seq: ++seq, reason: op.op === 'delete' ? 'user' : null, restored: null });
        receipts.set(op.opId, v);
        applied.push(op.opId);
        return { opId: op.opId, status: 'applied' as const, version: v };
      });
      if (s.dropResponseOnce) {
        s.dropResponseOnce = false;
        throw new ApiError('オフラインです', 0);
      }
      return { results };
    }),
    pull: vi.fn(async (cursor: number) => {
      const changes = [...rows.entries()]
        .filter(([, r]) => r.seq > cursor)
        .sort((a, b) => a[1].seq - b[1].seq)
        .map(([k, r]) => {
          const [entity, id] = k.split(':') as [PullChange['entity'], string];
          return { entity, id, version: r.version, deleted: r.deleted, reason: r.reason, record: r.data, restoredSessionId: r.restored };
        });
      return { cursor: seq, changes, hasMore: false };
    }),
    serverEdit(entity: string, id: string, data: Record<string, unknown> | null, reason: PullChange['reason'] = null) {
      const k = `${entity}:${id}`;
      const cur = rows.get(k);
      rows.set(k, { version: (cur?.version ?? 0) + 1, data, deleted: data == null, seq: ++seq, reason, restored: null });
    },
  };
  return s;
}

let database: MyTimeDB;
let now = 1_800_000_000_000;

function setup() {
  const server = fakeServer();
  const api = {
    config: async () => ({ googleConfigured: true, pushPublicKey: null, apiVersion: 2 }),
    me: async () => ({ user: { id: 'u', email: 'a@b', name: 'a' }, drive: { connected: true } }),
    push: server.push,
    pull: server.pull,
    notices: async () => ({ items: [] }),
  } as unknown as Api;
  const engine = new SyncEngine(database, api, () => now, () => 0.5);
  const repo = createRepo(database, () => now);
  return { server, engine, repo };
}

beforeEach(() => {
  database = new MyTimeDB(`sync-${Math.random()}`);
  now += 1000;
});

describe('同期エンジン', () => {
  it('オフラインで書いた変更を再接続後に送り、未同期キューを空にする', async () => {
    const { server, engine, repo } = setup();
    const t = makeTask({ title: 'オフラインで作成' }, now);
    await repo.saveTask(t, true);
    await repo.saveTask({ ...t, title: '編集' }, false);
    expect(await database.outbox.where('synced').equals(0).count()).toBe(2);
    await engine.checkAccount();
    expect(server.push).toHaveBeenCalledTimes(1);
    expect(server.push.mock.calls[0]![0]).toHaveLength(1); // 同じ記録への2操作は最新状態1件にまとめる
    expect(server.rows.get(`task:${t.id}`)?.data?.title).toBe('編集');
    expect(await database.outbox.where('synced').equals(0).count()).toBe(0);
    expect((await database.meta.get(`task:${t.id}`))?.version).toBe(1);
    engine.stop();
  });

  it('応答が届かず再送しても、冪等IDで二重に反映しない', async () => {
    const { server, engine, repo } = setup();
    await engine.checkAccount();
    const t = makeTask({ title: '再送' }, now);
    await repo.saveTask(t, true);
    server.dropResponseOnce = true;
    await engine.syncNow();
    expect(engine.snapshot.phase).toBe('offline');
    expect(await database.outbox.where('synced').equals(0).count()).toBe(1); // 端末側はまだ未確認
    await engine.syncNow();
    expect(server.applied).toHaveLength(1);
    expect(server.rows.get(`task:${t.id}`)?.version).toBe(1);
    expect(await database.outbox.where('synced').equals(0).count()).toBe(0);
    engine.stop();
  });

  it('失敗は指数バックオフで再試行し、続けば「お知らせ」に1件だけ出して成功で解消', async () => {
    const { server, engine, repo } = setup();
    await engine.checkAccount();
    await repo.saveTask(makeTask({ title: 'x' }, now), true);
    server.failNext = 3;
    await engine.syncNow();
    const d1 = engine.snapshot.nextRetryAt! - now;
    await engine.syncNow();
    const d2 = engine.snapshot.nextRetryAt! - now;
    await engine.syncNow();
    expect(d2).toBeGreaterThan(d1);
    const n = await database.notices.toArray();
    expect(n.filter((x) => x.resolvedAt == null).map((x) => x.title)).toEqual(['同期できていません']);
    await engine.syncNow();
    expect(engine.snapshot.phase).toBe('idle');
    expect((await database.notices.get('sync:failing'))?.resolvedAt).not.toBeNull();
    engine.stop();
  });

  it('サーバーの変更・削除を取り込む。ただし未同期の変更がある記録は消さない', async () => {
    const { server, engine, repo } = setup();
    await engine.checkAccount();
    const a = makeTask({ title: 'A' }, now);
    const b = makeTask({ title: 'B' }, now);
    await repo.saveTask(a, true);
    await repo.saveTask(b, true);
    await engine.syncNow();
    server.serverEdit('task', a.id, null, 'purge');
    server.serverEdit('task', b.id, null, 'purge');
    // B は端末で編集中（未送信）
    vi.spyOn(server, 'push').mockRejectedValueOnce(new ApiError('オフラインです', 0));
    await repo.saveTask({ ...b, title: 'B（未送信の編集）' }, false);
    await engine.pullAll();
    expect(await database.tasks.get(a.id)).toBeUndefined();
    expect((await database.tasks.get(b.id))?.title).toBe('B（未送信の編集）');
    engine.stop();
  });

  it('サーバー側の方が新しい衝突では、サーバーの内容で端末を更新する', async () => {
    const { server, engine, repo } = setup();
    await engine.checkAccount();
    const t = makeTask({ title: 'v1' }, now);
    await repo.saveTask(t, true);
    await engine.syncNow();
    server.serverEdit('task', t.id, { ...t, title: '別の端末で編集', updatedAt: now + 60_000 } as unknown as Record<string, unknown>);
    await repo.saveTask({ ...t, title: 'この端末の古い編集' }, false);
    await engine.pushAll();
    expect((await database.tasks.get(t.id))?.title).toBe('別の端末で編集');
    engine.stop();
  });
});

describe('Phase 1 → Phase 2 のデータ移行', () => {
  it('既存データを消さずに新しい項目の既定値を補う', async () => {
    const name = `migrate-${Math.random()}`;
    const v1 = new Dexie(name);
    v1.version(1).stores({ calendars: 'id, order', events: 'id, start, end, calendarId', tasks: 'id, plannedStart, checkAt, status, kind, eventId', subtasks: 'id, taskId, order', operationLog: '++seq, id, at, entityId', outbox: 'opId, at, synced', settings: 'key' });
    await v1.open();
    await v1.table('tasks').add({ id: 't1', title: '旧タスク', kind: 'do', icon: '📘', status: 'done', intervals: [], createdAt: 1, updatedAt: 1 });
    await v1.table('events').add({ id: 'e1', title: '旧予定', calendarId: 'cal-general', start: 10, end: 20, timeZone: 'Asia/Tokyo', notes: '', createdAt: 1, updatedAt: 1 });
    await v1.table('settings').add({ key: 'app', theme: 'dark' });
    v1.close();
    const v2 = new MyTimeDB(name);
    const t = (await v2.tasks.get('t1')) as Task;
    expect(t).toMatchObject({ title: '旧タスク', status: 'done', special: 'normal', tags: [], priority: 0, autoStartAt: null });
    expect(await v2.events.get('e1')).toMatchObject({ title: '旧予定', recurrence: null, exceptions: [], hideAfterEnd: false });
    expect(await v2.settings.get('app')).toMatchObject({ theme: 'dark', onboarded: true, analysisIncludePaused: false });
  });
});
