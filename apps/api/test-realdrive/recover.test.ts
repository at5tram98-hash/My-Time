import { env, SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { ENTITY_NAMES } from '@my-time/contracts';
import { canonicalJson, sha256Hex, type SnapshotBody } from '@my-time/domain';
import type { PullResult } from '@my-time/contracts';
import { recoverSnapshot } from '../src/lib/recovery';
import { installFakeGoogle } from '../test/fakeGoogle';

/**
 * 実 Drive の日次ファイル → 隔離した空 D1 への実復旧と照合（本番 D1 には接続しない）。
 * 出力は件数・一致/不一致のみ（本文・メールアドレスは出さない）。
 */
const text = env.REAL_SNAPSHOT_TEXT;
const body = JSON.parse(text) as SnapshotBody;
const userId = body.userId;
const report: Record<string, unknown> = {};

describe('実 Drive の日次ファイルからの実復旧', () => {
  it('ファイルの完全性（manifest の sha256 と一致）・形式', async () => {
    expect(body.kind).toBe('daily');
    expect([3, 4]).toContain(body.schemaVersion);
    const hash = await sha256Hex(text);
    const canonical = await sha256Hex(canonicalJson(body));
    report.sha256Given = Boolean(env.REAL_SNAPSHOT_SHA256);
    if (env.REAL_SNAPSHOT_SHA256) expect([hash, canonical]).toContain(env.REAL_SNAPSHOT_SHA256);
    report.tables = Object.fromEntries(Object.entries(body.tables).map(([k, v]) => [k, v.length]));
  });

  it('空の隔離 D1 へ書き戻し、記録・削除の印・設定・操作ログ・メタデータ・索引・同期世代が一致', async () => {
    const T = env.RECOVERY_DB;
    const before = await T.prepare('SELECT (SELECT COUNT(*) FROM records)+(SELECT COUNT(*) FROM users)+(SELECT COUNT(*) FROM operation_log) AS n').first<{ n: number }>();
    expect(before!.n).toBe(0);
    await recoverSnapshot(T, userId, body);

    // 記録（現役）
    for (const entity of ENTITY_NAMES) {
      const expected = (body.tables[entity] ?? []).map(({ __version, ...r }) => ({ id: r.id, version: __version, data: canonicalJson(r) })).sort((a, b) => String(a.id).localeCompare(String(b.id)));
      const rows = (await T.prepare('SELECT id, version, data FROM records WHERE user_id = ? AND entity = ? AND deleted = 0 ORDER BY id').bind(userId, entity).all<{ id: string; version: number; data: string }>()).results;
      expect(rows.map((r) => ({ id: r.id, version: r.version, data: canonicalJson(JSON.parse(r.data)) }))).toEqual(expected.map((e) => ({ ...e, data: canonicalJson(JSON.parse(e.data)) })));
    }
    // 削除の印
    const tombs = (await T.prepare('SELECT entity, id, version, delete_reason AS reason FROM records WHERE user_id = ? AND deleted = 1 ORDER BY entity, id').bind(userId).all()).results;
    expect(tombs).toEqual((body.tables.tombstones ?? []).map((t) => ({ entity: t.entity, id: t.id, version: t.version, reason: t.reason })).sort((a, b) => `${a.entity}:${a.id}`.localeCompare(`${b.entity}:${b.id}`)));
    // 設定
    const settings = (await T.prepare('SELECT data, updated_at FROM user_settings WHERE user_id = ?').bind(userId).all<{ data: string; updated_at: number }>()).results;
    expect(settings.map((s) => ({ data: canonicalJson(JSON.parse(s.data)), at: s.updated_at }))).toEqual((body.tables.settings ?? []).map(({ key: _k, __updatedAt, ...s }) => ({ data: canonicalJson(s), at: __updatedAt })));
    // 操作ログ
    const log = (await T.prepare('SELECT at, entity, entity_id, action, detail FROM operation_log WHERE user_id = ? ORDER BY seq').bind(userId).all()).results;
    expect(log).toEqual((body.tables.operationLog ?? []).map((r) => ({ at: r.at, entity: r.entity, entity_id: r.entity_id, action: r.action, detail: r.detail ?? null })));
    // メタデータ（バックアップ一覧・アーカイブ索引・期限削除の記録・復元セッション・送信受領）
    for (const [key, table] of [['backupManifests', 'backup_manifests'], ['archiveEntries', 'archive_entries'], ['purgeLedger', 'purge_ledger'], ['restorationSessions', 'restoration_sessions'], ['syncReceipts', 'sync_receipts']] as const) {
      const n = (await T.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`).bind(userId).first<{ n: number }>())!.n;
      expect(n, table).toBe((body.tables[key] ?? []).length);
    }
    // 索引（migration で作る索引が復旧先にもあり、本体と同じ）
    const idx = async (db: D1Database) => (await db.prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name").all<{ name: string }>()).results.map((r) => r.name);
    expect(await idx(T)).toEqual(await idx(env.DB));
    report.indexes = (await idx(T)).length;
    // 同期世代：カーソルはバックアップ時点以上、世代は新しくなる（古い端末に全件の再取得を促す）
    const seq = await T.prepare('SELECT seq, generation FROM sync_seq WHERE user_id = ?').bind(userId).first<{ seq: number; generation: string }>();
    const backedSeq = (body.tables.syncSequence?.[0]?.seq as number | undefined) ?? 0;
    expect(seq!.seq).toBeGreaterThanOrEqual(backedSeq);
    expect(seq!.generation).not.toBe(body.tables.syncSequence?.[0]?.generation);
    // 認証情報は復旧しない
    for (const table of ['sessions', 'oauth_grants', 'push_subscriptions']) {
      const n = await T.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<{ n: number }>().catch(() => ({ n: 0 }));
      expect(n!.n, table).toBe(0);
    }
    report.recovered = {
      active: (await T.prepare('SELECT COUNT(*) AS n FROM records WHERE user_id = ? AND deleted = 0').bind(userId).first<{ n: number }>())!.n,
      tombstones: tombs.length,
      settings: settings.length,
      operationLog: log.length,
      backedSeq,
    };
  });

  it('復旧後の再認証と、古いカーソル・古い世代からの再同期', async () => {
    // 本テスト環境の DB（隔離・空）へ同じファイルを復旧し、偽の Google で同じアカウント（google_sub）として再ログイン
    await recoverSnapshot(env.DB, userId, body);
    const account = body.tables.account?.[0];
    expect(account).toBeTruthy();
    const fg = await installFakeGoogle();
    const r1 = await SELF.fetch('http://localhost:8787/api/auth/login', { redirect: 'manual' });
    const loc = new URL(r1.headers.get('location')!);
    const browser = r1.headers.get('set-cookie')!.split(';')[0]!;
    await fg.addCode('real-code', { sub: account!.google_sub as string, email: 'recovered@example.invalid', name: '復旧' });
    const r2 = await SELF.fetch(`http://localhost:8787/api/auth/callback?state=${loc.searchParams.get('state')}&code=real-code`, { redirect: 'manual', headers: { cookie: browser } });
    expect(r2.headers.get('location')).toBe('/?login=ok');
    const cookie = r2.headers.getSetCookie().find((x) => x.startsWith('mt_session='))!.split(';')[0]!;
    const same = await env.DB.prepare('SELECT id FROM users WHERE google_sub = ?').bind(account!.google_sub as string).first<{ id: string }>();
    expect(same!.id).toBe(userId); // 新しいアカウントを作らず、復旧したアカウントへ入る
    const pull = async (cursor: number) => {
      const all: PullResult['changes'] = [];
      let res: PullResult;
      let c = cursor;
      do {
        res = await (await SELF.fetch(`http://localhost:8787/api/sync/pull?cursor=${c}`, { headers: { cookie, 'x-mytime': '1', 'x-mytime-account': userId } })).json<PullResult>();
        all.push(...res.changes);
        c = res.cursor;
      } while (res.hasMore);
      return { generation: res.generation, changes: all };
    };
    const oldGeneration = body.tables.syncSequence?.[0]?.generation;
    const backedSeq = (body.tables.syncSequence?.[0]?.seq as number | undefined) ?? 0;
    const fromOld = await pull(backedSeq);
    expect(fromOld.generation).not.toBe(oldGeneration); // 古い端末は世代の違いで全件を取り直す
    const fromZero = await pull(0);
    const active = ENTITY_NAMES.reduce((n, e) => n + (body.tables[e]?.length ?? 0), 0);
    const tombs = body.tables.tombstones?.length ?? 0;
    expect(fromZero.changes.filter((c) => !c.deleted).length).toBe(active);
    expect(fromZero.changes.filter((c) => c.deleted).length).toBe(tombs);
    report.resync = { fromOldCursorChanges: fromOld.changes.length, fromZeroChanges: fromZero.changes.length, generationChanged: true };
    console.log('REALDRIVE_REPORT ' + JSON.stringify(report));
  });
});
