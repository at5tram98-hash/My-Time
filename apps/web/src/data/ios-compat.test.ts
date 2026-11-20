import 'fake-indexeddb/auto';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { expandEvent, normalizeTask } from '@my-time/domain';
import { taskSchema } from '@my-time/contracts';
import { MyTimeDB } from './db';
import { importDevice, readDevice } from './transfer';

/**
 * iOS 版（ios/Packages/MyTimeCore）が書き出したファイルを、Web 版の「データの移行」で読めるか。
 * 基準データは Swift のテスト（IOSExportFixture）が作る。iOS 版はログインなしの領域として書き出すので、
 * Web 版でも「この端末（ログインなし）」の領域へ取り込む。
 */
// テストはリポジトリのルートで実行する（vitest.workspace.ts）
// リポジトリのルートからでも apps/web からでも実行できるようにする
const REL = 'ios/Packages/MyTimeCore/Tests/MyTimeCoreTests/Fixtures/ios-export.json';
const FIXTURE = [resolve(process.cwd(), REL), resolve(process.cwd(), '../..', REL)].find((p) => existsSync(p)) ?? resolve(process.cwd(), REL);
const dbs: MyTimeDB[] = [];
afterEach(async () => { for (const db of dbs.splice(0)) await db.delete(); });

describe('iOS 版から Web 版への移行', () => {
  it('チェックサム・スキーマの検証に通り、追加だけで取り込め、2回目は何も増えない', async () => {
    const text = readFileSync(FIXTURE, 'utf8');
    const file = await readDevice(text);
    expect(file.body.origin).toBe('ios-app');
    const db = new MyTimeDB(`ios-compat-${crypto.randomUUID()}`);
    dbs.push(db);
    const added = await importDevice(db, text);
    expect(added).toBe(2 + 1 + 1 + 1); // 既定カレンダー2・予定1・タスク1・サブタスク1
    expect((await db.calendars.toArray()).map((calendar) => calendar.id).sort()).toEqual(['cal-general', 'cal-mio']);
    expect(await importDevice(db, text)).toBe(0);
    const t = (await db.tasks.get('ios-task-1'))!;
    expect(taskSchema.safeParse(normalizeTask(t)).success).toBe(true);
    expect(t).toMatchObject({ title: 'iOSで作った課題 "引用" 😀', status: 'running', estimateMinutes: 60 });
    expect(t.intervals).toHaveLength(1);
    const ev = (await db.events.get('ios-event-1'))!;
    expect(expandEvent(ev, ev.start, ev.start + 21 * 86_400_000)).toHaveLength(3);
    expect((await db.settings.get('app'))?.laneFocus).toBe('detail');
    expect(await db.operationLog.filter((l) => l.action === 'start').count()).toBe(1);
  });
});
