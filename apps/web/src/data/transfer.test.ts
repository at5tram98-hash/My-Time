import 'fake-indexeddb/auto';
import { afterEach, describe, expect, it } from 'vitest';
import { makeTask, defaultCalendars, canonicalJson, sha256Hex } from '@my-time/domain';
import { MyTimeDB, accountDbName } from './db';
import { exportDevice, importDevice } from './transfer';

const dbs: MyTimeDB[] = [];
const open = (owner?: string) => {
  const db = new MyTimeDB(owner ? accountDbName(owner) : `transfer-${crypto.randomUUID()}`);
  dbs.push(db); return db;
};
afterEach(async () => { for (const db of dbs.splice(0)) await db.delete(); });

describe('端末データ移行', () => {
  it('異なるOriginへ全記録・設定・ログ・退避データを復旧し、再取込で二重作成しない', async () => {
    const source = open(), target = open();
    const task = makeTask({ id: 'offline-task', title: 'オフラインの課題' }, 1000);
    await source.tasks.put(task);
    await source.calendars.bulkPut(defaultCalendars(1000));
    await source.operationLog.add({ id: 'log-1', at: 1000, entity: 'task', entityId: task.id, action: 'create' });
    await source.recovery.put({ key: 'recovery-1', entity: 'task', id: task.id, at: 1000, reason: 'tombstone', record: { ...task } });
    const text = await exportDevice(source, 'https://at5tram98-hash.github.io', 2000);
    expect(await importDevice(target, text)).toBe(4);
    expect(await target.tasks.get(task.id)).toEqual(task);
    expect(await source.tasks.get(task.id)).toEqual(task);
    expect(await target.recovery.count()).toBe(1);
    expect(await target.operationLog.where('id').equals('log-1').count()).toBe(1);
    expect(await target.outbox.where('synced').equals(0).count()).toBe(4);
    expect(await importDevice(target, text)).toBe(0);
    expect(await target.tasks.count()).toBe(1);
  });
  it('改ざん・別アカウント・ID衝突で全体を中止し、途中の書込を残さない', async () => {
    const source = open('owner-a'), target = open('owner-b');
    await source.tasks.put(makeTask({ id: 'same', title: '元' }, 1000));
    const text = await exportDevice(source, 'https://old.example');
    await expect(importDevice(target, text)).rejects.toThrow('同じGoogle');
    expect(await target.tasks.count()).toBe(0);
    const broken = JSON.parse(text); broken.body.owner = 'owner-b';
    await expect(importDevice(target, JSON.stringify(broken))).rejects.toThrow('壊れ');
    broken.sha256 = await sha256Hex(canonicalJson(broken.body));
    await target.tasks.put(makeTask({ id: 'same', title: '移行先の編集' }, 2000));
    await expect(importDevice(target, JSON.stringify(broken))).rejects.toThrow('同じID');
    expect((await target.tasks.get('same'))?.title).toBe('移行先の編集');
    expect(await target.outbox.count()).toBe(0);
  });
  it('無効なレコードをハッシュだけでは信用せず拒否する', async () => {
    const source = open(), target = open();
    await source.tasks.put(makeTask({ id: 'x', title: 'test' }, 1000));
    const file = JSON.parse(await exportDevice(source, 'https://old.example'));
    file.body.tables.tasks[0].title = '';
    file.sha256 = await sha256Hex(canonicalJson(file.body));
    await expect(importDevice(target, JSON.stringify(file))).rejects.toThrow('不正');
    expect(await target.tasks.count()).toBe(0);
  });
});
