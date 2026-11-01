import 'fake-indexeddb/auto';
import Dexie from 'dexie';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { makeTask, type Task } from '@my-time/domain';
import type { PullChange, PushResult, SyncOp } from '@my-time/contracts';
import { accountDbName, LOCAL_DB, MyTimeDB } from '../data/db';
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
        // 本物と同じく、削除済み（tombstone）は端末の内容より優先
        if (cur?.deleted) {
          if (op.op === 'delete') return { opId: op.opId, status: 'applied' as const, version: cur.version };
          return { opId: op.opId, status: 'conflict' as const, version: cur.version, serverRecord: null, serverDeleted: true, deleteReason: cur.reason };
        }
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
let userId = 'u';

function makeApi(server: ReturnType<typeof fakeServer>, who: () => string = () => userId) {
  const settings: { data: Record<string, unknown> } = { data: {} };
  const api = {
    config: async () => ({ googleConfigured: true, pushPublicKey: null, apiVersion: 3 }),
    me: async () => ({ user: { id: who(), email: `${who()}@example.com`, name: 'a' }, drive: { connected: true } }),
    push: vi.fn(async (ops: SyncOp[], account: string) => {
      if (account !== who()) throw new ApiError('アカウントが一致しません', 409);
      return server.push(ops);
    }),
    pull: vi.fn(async (cursor: number, account: string) => {
      if (account !== who()) throw new ApiError('アカウントが一致しません', 409);
      return server.pull(cursor);
    }),
    getSettings: vi.fn(async () => settings.data),
    putSettings: vi.fn(async (data: Record<string, unknown>) => {
      settings.data = data;
      return { ok: true };
    }),
    logout: vi.fn(async () => ({ ok: true })),
    notices: async () => ({ items: [] }),
  };
  return { api: api as unknown as Api, raw: api, settings };
}

function setup(dbForEngine: MyTimeDB = database) {
  const server = fakeServer();
  const { api, raw, settings } = makeApi(server);
  const switched: { name: string; flash?: string }[] = [];
  const opened = new Map<string, MyTimeDB>();
  const hooks = {
    switchTo: (name: string, flash?: string) => void switched.push({ name, flash }),
    open: (name: string) => {
      const d = opened.get(name) ?? new MyTimeDB(name);
      opened.set(name, d);
      return d;
    },
  };
  const engine = new SyncEngine(dbForEngine, api, () => now, () => 0.5, hooks);
  const repo = createRepo(dbForEngine, () => now);
  return { server, engine, repo, api: raw, settings, switched, hooks };
}

beforeEach(() => {
  // 各テストで別のアカウント・別の保存領域（ログイン中のアカウントの領域）
  userId = `u${Math.random().toString(36).slice(2)}`;
  database = new MyTimeDB(accountDbName(userId));
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

  it('削除は未同期の変更より優先し、未送信の内容を退避してから取り込む', async () => {
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
    expect(await database.tasks.get(b.id)).toBeUndefined();
    expect((await database.recovery.toArray()).find((r) => r.id === b.id)?.record.title).toBe('B（未送信の編集）');
    expect((await database.syncState.get('sync'))?.cursor).toBeGreaterThan(0);
    engine.stop();
  });

  it('期限削除された記録をオフラインで編集していても、再接続後は削除が優先され復活しない', async () => {
    const { server, engine, repo } = setup();
    await engine.checkAccount();
    const b = makeTask({ title: 'B' }, now);
    await repo.saveTask(b, true);
    await engine.syncNow();
    server.serverEdit('task', b.id, null, 'purge');
    // オフライン中に、削除後の時刻で編集
    now += 86_400_000;
    await repo.saveTask({ ...b, title: 'B（オフラインで編集）' }, false);
    await engine.syncNow();
    expect(await database.tasks.get(b.id)).toBeUndefined();
    expect(server.rows.get(`task:${b.id}`)).toMatchObject({ deleted: true, data: null });
    expect(await database.outbox.where('synced').equals(0).count()).toBe(0);
    const n = await database.notices.get(`sync:tombstone:task:${b.id}`);
    expect(n?.title).toBe('削除済みのデータへの変更は反映されませんでした');
    // 変更内容そのものは端末の操作ログに残っている
    expect((await database.operationLog.where('entityId').equals(b.id).toArray()).length).toBeGreaterThanOrEqual(2);
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

describe('アカウントごとの保存領域', () => {
  it('アカウントAの領域を表示中にBでログインしても、Aのデータは送らずBの領域へ切り替える（Aの未送信は残る）', async () => {
    const { engine, repo, api, switched } = setup();
    const a = userId;
    await repo.saveTask(makeTask({ title: 'Aの未送信' }, now), true);
    userId = 'b-account'; // 同じブラウザで別のアカウントにログインし直した
    await engine.checkAccount();
    expect(api.push).not.toHaveBeenCalled();
    expect(api.pull).not.toHaveBeenCalled();
    expect(switched).toEqual([{ name: accountDbName('b-account'), flash: expect.stringContaining('未送信の変更1件') }]);
    expect(database.name).toBe(accountDbName(a));
    expect(await database.outbox.where('synced').equals(0).count()).toBe(1);
    // B の領域は設定だけ引き継ぎ、データは空。初回セットアップは出さない
    const b = new MyTimeDB(accountDbName('b-account'));
    expect(await b.tasks.count()).toBe(0);
    expect(await b.settings.get('app')).toMatchObject({ onboarded: true });
  });

  it('送信の途中で別アカウントになっていたら（409）、送らずに確認し直す', async () => {
    const { engine, repo, api, switched } = setup();
    await engine.checkAccount();
    await repo.saveTask(makeTask({ title: 'x' }, now), true);
    const me = userId;
    userId = 'other';
    // me の確認より前に、送信の時点で別アカウントだった
    (engine as unknown as { status: { me: { user: { id: string } } } }).status.me.user.id = me;
    await engine.syncNow();
    expect(api.push).toHaveBeenLastCalledWith(expect.anything(), me);
    expect(switched.at(-1)?.name).toBe(accountDbName('other'));
    expect(await database.outbox.where('synced').equals(0).count()).toBe(1);
  });

  it('ログインしていない間のデータがあれば、件数と移行先を示して確認するまで何も送らない → 移すと移行先で同期', async () => {
    const local = new MyTimeDB(`local-${Math.random()}`); // 持ち主のない領域＝ログインしていない間のデータ
    const { engine, api, switched, hooks } = setup(local);
    const r = createRepo(local, () => now);
    await r.ensureDefaults();
    await r.saveTask(makeTask({ title: 'ログイン前に作成' }, now), true);
    await r.saveTask(makeTask({ title: 'もう1件' }, now), true);
    await engine.checkAccount();
    expect(engine.snapshot.phase).toBe('chooseAccount');
    expect(engine.snapshot.pendingMigration).toMatchObject({ me: { user: { id: userId } }, summary: { tasks: 2, calendars: 0, total: 2 } });
    expect(api.push).not.toHaveBeenCalled();
    const moved = await engine.resolveMigration(true);
    expect(moved).toBe(5); // タスク2件＋初期カレンダー3件（移行先にまだない）
    expect(switched.at(-1)).toEqual({ name: accountDbName(userId), flash: expect.stringContaining('タスク2件を') });
    const target = hooks.open(accountDbName(userId));
    expect((await target.tasks.toArray()).map((t) => t.title).sort()).toEqual(['もう1件', 'ログイン前に作成']);
    expect(await target.outbox.where('synced').equals(0).count()).toBe(5);
    expect(await local.tasks.count()).toBe(2); // 復旧用の原本を残す
    // 移行先の領域で起動し直すと送信される
    const { engine: e2, api: api2 } = setup(target);
    await e2.checkAccount();
    expect(api2.push).toHaveBeenCalledTimes(1);
    expect(await target.outbox.where('synced').equals(0).count()).toBe(0);
    e2.stop();
  });

  it('移さないを選ぶと、この端末のデータはそのまま残し、アカウントの領域へ切り替える', async () => {
    const local = new MyTimeDB(`local-${Math.random()}`);
    const { engine, switched, hooks } = setup(local);
    await createRepo(local, () => now).saveTask(makeTask({ title: '端末だけ' }, now), true);
    await engine.checkAccount();
    expect(engine.snapshot.phase).toBe('chooseAccount');
    await engine.resolveMigration(false);
    expect(switched.at(-1)?.name).toBe(accountDbName(userId));
    expect((await local.tasks.toArray()).map((t) => t.title)).toEqual(['端末だけ']);
    expect(await hooks.open(accountDbName(userId)).tasks.count()).toBe(0);
  });

  it('ログインしていない間のデータがなければ確認なしで切り替える', async () => {
    const local = new MyTimeDB(`local-${Math.random()}`);
    const { engine, switched, api } = setup(local);
    await createRepo(local, () => now).ensureDefaults();
    await engine.checkAccount();
    expect(engine.snapshot.phase).toBe('switching');
    expect(switched).toEqual([{ name: accountDbName(userId), flash: expect.stringContaining('ログインしました') }]);
    expect(api.push).not.toHaveBeenCalled();
  });

  it('ログアウト → 未送信は残し、ログインしていない領域へ。同じアカウントで再ログインすると続きから送る', async () => {
    const { engine, repo, api, switched } = setup();
    await engine.checkAccount();
    api.push.mockRejectedValueOnce(new ApiError('オフラインです', 0));
    await repo.saveTask(makeTask({ title: 'オフラインで作成' }, now), true);
    await engine.syncNow();
    await engine.logout();
    expect(api.logout).toHaveBeenCalled();
    expect(switched.at(-1)).toEqual({ name: LOCAL_DB, flash: expect.stringContaining('未送信の変更1件') });
    expect(await database.outbox.where('synced').equals(0).count()).toBe(1);
    // 再ログイン（同じアカウント・同じ領域）
    const again = setup();
    await again.engine.checkAccount();
    expect(again.api.push).toHaveBeenCalledTimes(1);
    expect(await database.outbox.where('synced').equals(0).count()).toBe(0);
    again.engine.stop();
  });

  it('セッション切れ（401）では領域を切り替えず、未送信も消さない', async () => {
    const { engine, repo, api } = setup();
    await engine.checkAccount();
    await repo.saveTask(makeTask({ title: 'x' }, now), true);
    api.push.mockRejectedValueOnce(new ApiError('ログインが必要です', 401));
    await engine.syncNow();
    expect(engine.snapshot.phase).toBe('loggedOut');
    expect(engine.owner).toBe(userId);
    expect(await database.outbox.where('synced').equals(0).count()).toBe(1);
  });

  it('設定：この領域で初めての同期ではサーバーの設定を取り込み、その後は変更したときだけ送る', async () => {
    const { engine, repo, api, settings } = setup();
    settings.data = { theme: 'dark', suggestFromHour: 9 };
    await engine.checkAccount();
    // サーバーの設定が優先して取り込まれ、足りない項目を補った完全な形でサーバーにも残る
    expect(await database.settings.get('app')).toMatchObject({ theme: 'dark', suggestFromHour: 9 });
    expect(settings.data).toMatchObject({ theme: 'dark', suggestFromHour: 9 });
    const base = api.putSettings.mock.calls.length;
    await engine.syncNow();
    expect(api.putSettings).toHaveBeenCalledTimes(base); // 変更がなければ送らない
    await repo.updateSettings({ theme: 'light' });
    await engine.syncNow();
    expect(api.putSettings).toHaveBeenCalledTimes(base + 1);
    expect(settings.data).toMatchObject({ theme: 'light', suggestFromHour: 9 });
    await engine.syncNow();
    expect(api.putSettings).toHaveBeenCalledTimes(base + 1);
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
    expect(t).toMatchObject({ title: '旧タスク', icon: '📘', status: 'done', special: 'normal', tags: [], priority: 0, autoStartAt: null }); // 旧形式のアイコン値は書き換えない（表示時に読み替える）
    expect(await v2.events.get('e1')).toMatchObject({ title: '旧予定', recurrence: null, exceptions: [], hideAfterEnd: false });
    expect(await v2.settings.get('app')).toMatchObject({ theme: 'dark', onboarded: true, analysisIncludePaused: false });
  });
});


it('古い削除拒否の再送応答でも、進んだカーソルを巻き戻して後の復元を取り逃がさない', async () => {
  const { server, engine, repo, api } = setup();
  await engine.checkAccount();
  const task = makeTask({ id: 'restored-later', title: '元' }, now);
  await repo.saveTask(task, true);
  await engine.syncNow();
  server.serverEdit('task', task.id, null, 'purge');
  server.serverEdit('task', task.id, { ...task, title: '復元後', updatedAt: now + 50 });
  await engine.pullAll(); // cursor has already passed the restoration
  await repo.saveTask({ ...task, title: '未送信の編集', updatedAt: now + 100 }, false);
  api.push.mockImplementationOnce(async (ops: SyncOp[]) => ({ results: ops.map((o) => ({ opId: o.opId, status: 'conflict', version: 2, serverDeleted: true, serverRecord: null, deleteReason: 'purge' })) }));
  await engine.syncNow();
  expect((await database.tasks.get(task.id))?.title).toBe('復元後');
  expect((await database.recovery.toArray())[0]?.record.title).toBe('未送信の編集');
  expect((await database.meta.get(`task:${task.id}`))?.version).toBe(3);
  engine.stop();
});

it('応答待ちの間の新しい端末編集を、古い競合応答で上書きしない', async () => {
  const { engine, repo, api } = setup();
  await engine.checkAccount();
  const task = makeTask({ id: 'in-flight-edit', title: '最初' }, now);
  await repo.saveTask(task, true);
  api.push.mockImplementationOnce(async (ops: SyncOp[]) => {
    await repo.saveTask({ ...task, title: '送信中の追加編集', updatedAt: now + 500 }, false);
    return { results: ops.map((o) => ({ opId: o.opId, status: 'conflict', version: 1, serverRecord: { ...task, title: '古いサーバー応答' } })) };
  });
  await engine.syncNow();
  expect((await database.tasks.get(task.id))?.title).toBe('送信中の追加編集');
  expect(await database.recovery.count()).toBeGreaterThan(0);
  engine.stop();
});


it('サーバー全体の復旧世代が変わったら、古い高いカーソルを捨てて全件取得する', async () => {
  const { engine, server, api } = setup();
  await engine.checkAccount();
  const task = makeTask({ id: 'disaster-recovered', title: 'バックアップから戻した' }, now);
  server.serverEdit('task', task.id, { ...task });
  const st = (await database.syncState.get('sync'))!;
  await database.syncState.put({ ...st, cursor: 50000, generation: 'old-generation' });
  api.pull.mockImplementationOnce(async () => ({ cursor: 50000, changes: [], hasMore: false, generation: 'new-generation' }));
  await engine.pullAll();
  expect(api.pull).toHaveBeenLastCalledWith(0, userId);
  expect((await database.tasks.get(task.id))?.title).toBe('バックアップから戻した');
  expect((await database.syncState.get('sync'))?.generation).toBe('new-generation');
  engine.stop();
});
