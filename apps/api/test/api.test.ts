import { env, fetchMock, SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import { makeEvent, makeTask, type CalEvent, type Task } from '@my-time/domain';
import type { PullResult, PushResult, SyncOp } from '@my-time/contracts';
import { installFakeGoogle, type FakeGoogle } from './fakeGoogle';
import { runDailyBackup, runRetention } from '../src/jobs/backup';
import { runNotifications } from '../src/jobs/notify';
import { encryptPayload, vapidAuthorization } from '../src/lib/webpush';
import { b64url, fromB64url } from '../src/lib/crypto';
import { scheduled } from '../src/index';
import type { Env } from '../src/env';

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 10, 30, 13); // 2026-11-30 22:00 JST
const E = env as unknown as Env;
let fg: FakeGoogle;

beforeEach(async () => {
  fg = await installFakeGoogle();
});

async function login(sub = 'g-1'): Promise<{ cookie: string; userId: string }> {
  const r1 = await SELF.fetch('http://localhost:8787/api/auth/login', { redirect: 'manual' });
  expect(r1.status).toBe(302);
  const loc = new URL(r1.headers.get('location')!);
  expect(loc.searchParams.get('code_challenge_method')).toBe('S256');
  expect(loc.searchParams.get('scope')).toContain('drive.file');
  expect(loc.searchParams.get('scope')).not.toMatch(/\/auth\/drive(\s|$)/);
  const code = `code-${sub}`;
  await fg.addCode(code, { sub, email: `${sub}@example.com`, name: 'ゆうき' });
  const r2 = await SELF.fetch(`http://localhost:8787/api/auth/callback?state=${loc.searchParams.get('state')}&code=${code}`, { redirect: 'manual' });
  expect(r2.headers.get('location')).toBe('/?login=ok');
  const set = r2.headers.get('set-cookie')!;
  expect(set).toMatch(/HttpOnly/i);
  expect(set).toMatch(/SameSite=Lax/i);
  const cookie = set.split(';')[0]!;
  const u = await E.DB.prepare('SELECT id FROM users WHERE google_sub = ?').bind(sub).first<{ id: string }>();
  return { cookie, userId: u!.id };
}

const api = (cookie: string, path: string, init: RequestInit & { now?: number } = {}) =>
  SELF.fetch(`http://localhost:8787/api${path}`, { ...init, headers: { cookie, 'x-mytime': '1', 'content-type': 'application/json', 'x-mytime-now': String(init.now ?? NOW), ...(init.headers ?? {}) } });

let opN = 0;
const putOp = <T extends { id: string; updatedAt: number }>(entity: SyncOp['entity'], record: T, baseVersion = 0): SyncOp => ({ opId: `op-${++opN}-${crypto.randomUUID().slice(0, 8)}`, entity, entityId: record.id, op: 'put', record: record as unknown as Record<string, unknown>, baseVersion, clientUpdatedAt: record.updatedAt });

async function push(cookie: string, ops: SyncOp[]): Promise<PushResult> {
  const r = await api(cookie, '/sync/push', { method: 'POST', body: JSON.stringify({ ops }) });
  expect(r.status).toBe(200);
  return r.json();
}

async function pullAll(cookie: string, cursor = 0): Promise<PullResult> {
  return (await api(cookie, `/sync/pull?cursor=${cursor}`)).json();
}

describe('認証（OAuth 認可コード + PKCE、サーバー側セッション）', () => {
  it('設定済みを返し、ログインでセッションCookieを発行。リフレッシュトークンは暗号化して保存', async () => {
    expect(await (await SELF.fetch('http://localhost:8787/api/config')).json()).toMatchObject({ googleConfigured: true });
    const { cookie, userId } = await login();
    const me = await (await api(cookie, '/me')).json<{ user: { email: string }; drive: { connected: boolean } }>();
    expect(me).toMatchObject({ user: { email: 'g-1@example.com' }, drive: { connected: true } });
    const g = await E.DB.prepare('SELECT refresh_token_enc FROM oauth_grants WHERE user_id = ?').bind(userId).first<{ refresh_token_enc: string }>();
    expect(g!.refresh_token_enc).not.toContain('rt-g-1');
    const s = await E.DB.prepare('SELECT id FROM sessions').all<{ id: string }>();
    expect(s.results.every((r) => r.id !== cookie.split('=')[1])).toBe(true); // 生のトークンは保存しない
  });

  it('state の不一致・使い回しは拒否', async () => {
    const r = await SELF.fetch('http://localhost:8787/api/auth/callback?state=bogus&code=x', { redirect: 'manual' });
    expect(r.headers.get('location')).toMatch(/login=error/);
    expect(r.headers.get('set-cookie')).toBeNull();
  });

  it('未ログインは401、独自ヘッダーのない書き込みは403', async () => {
    expect((await SELF.fetch('http://localhost:8787/api/me')).status).toBe(401);
    const { cookie } = await login();
    const r = await SELF.fetch('http://localhost:8787/api/sync/push', { method: 'POST', headers: { cookie, 'content-type': 'application/json' }, body: '{"ops":[]}' });
    expect(r.status).toBe(403);
  });
});

describe('同期（冪等ID・版による衝突検出）', () => {
  it('同じ操作の再送は二重に反映しない', async () => {
    const { cookie } = await login();
    const t = makeTask({ title: '課題', plannedStart: NOW, plannedEnd: NOW + 3_600_000 }, NOW);
    const op = putOp('task', t);
    const a = await push(cookie, [op]);
    const b = await push(cookie, [op]);
    expect(a.results[0]).toMatchObject({ status: 'applied', version: 1 });
    expect(b.results[0]).toMatchObject({ status: 'duplicate', version: 1 });
    const pulled = await pullAll(cookie);
    expect(pulled.changes).toHaveLength(1);
  });

  it('古い版からの変更は、サーバー側が新しければ conflict としてサーバーの最新を返す', async () => {
    const { cookie } = await login();
    const t = makeTask({ title: 'v1' }, NOW);
    await push(cookie, [putOp('task', t)]);
    await push(cookie, [putOp('task', { ...t, title: 'v2', updatedAt: NOW + 2000 }, 1)]);
    const stale = await push(cookie, [putOp('task', { ...t, title: '古い端末', updatedAt: NOW + 1000 }, 1)]);
    expect(stale.results[0]).toMatchObject({ status: 'conflict', version: 2, serverRecord: { title: 'v2' } });
    const newer = await push(cookie, [putOp('task', { ...t, title: 'より新しい', updatedAt: NOW + 3000 }, 1)]);
    expect(newer.results[0]).toMatchObject({ status: 'applied', version: 3 });
  });

  it('スキーマ違反は保存しない', async () => {
    const { cookie } = await login();
    const bad = { ...makeTask({ title: 'x' }, NOW), plannedStart: NOW, plannedEnd: NOW - 1 };
    const r = await push(cookie, [putOp('task', bad)]);
    expect(r.results[0]!.status).toBe('rejected');
    expect((await pullAll(cookie)).changes).toHaveLength(0);
  });

  it('pull はカーソルで差分だけ返す（他ユーザーのデータは見えない）', async () => {
    const a = await login('g-a');
    const b = await login('g-b');
    await push(a.cookie, [putOp('task', makeTask({ title: 'A1' }, NOW))]);
    const first = await pullAll(a.cookie);
    await push(a.cookie, [putOp('task', makeTask({ title: 'A2' }, NOW))]);
    const next = await pullAll(a.cookie, first.cursor);
    expect(next.changes.map((c) => c.record?.title)).toEqual(['A2']);
    expect((await pullAll(b.cookie)).changes).toHaveLength(0);
  });
});

async function seedForRetention(cookie: string) {
  const old = makeTask({ id: 'old', title: '40日前', plannedStart: NOW - 40 * DAY, plannedEnd: NOW - 40 * DAY + 3_600_000 }, NOW - 41 * DAY);
  const recent = makeTask({ id: 'recent', title: '昨日', plannedStart: NOW - DAY, plannedEnd: NOW - DAY + 3_600_000 }, NOW - 2 * DAY);
  const hold = makeTask({ id: 'hold', title: '提出期限のみ', special: 'assignment', assignment: { content: '', submitMethod: '', submitTo: '', deadline: NOW - 60 * DAY } }, NOW - 90 * DAY);
  const night = makeEvent({ id: 'night', title: '夜勤', calendarId: 'cal-job', start: Date.parse('2026-11-29T22:00:00+09:00'), end: Date.parse('2026-11-30T06:00:00+09:00'), hideAfterEnd: true }, NOW - 2 * DAY);
  const series = makeEvent({ id: 'series', title: '毎週の授業', calendarId: 'cal-class', start: NOW - 60 * DAY, end: NOW - 60 * DAY + 5_400_000, recurrence: { freq: 'weekly', interval: 1, byWeekday: null, until: null } }, NOW - 60 * DAY);
  const oldSub = { id: 'sub-old', taskId: 'old', title: '章1', done: true, completedAt: NOW - 40 * DAY, order: 0, createdAt: NOW - 41 * DAY, updatedAt: NOW - 40 * DAY };
  await push(cookie, [putOp('task', old), putOp('task', recent), putOp('task', hold), putOp('event', night), putOp('event', series), putOp('subtask', oldSub)]);
}

describe('Driveバックアップ（読み戻し検証で初めて成功）', () => {
  it('ユーザーから見えるフォルダーに保存し、件数・ハッシュを検証して verified', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    const r = await runDailyBackup(E, userId, NOW);
    expect(r.ok).toBe(true);
    const folder = [...fg.files.values()].find((f) => f.mimeType === 'application/vnd.google-apps.folder');
    expect(folder?.name).toBe('My Time Backup');
    const m = await E.DB.prepare('SELECT status, counts, sha256 FROM backup_manifests WHERE id = ?').bind(r.manifestId).first<{ status: string; counts: string }>();
    expect(m!.status).toBe('verified');
    expect(JSON.parse(m!.counts)).toMatchObject({ task: 3, event: 2, subtask: 1 });
  });

  it('読み戻しが壊れていれば失敗扱い・お知らせ・期限削除はしない', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    fg.fail.corruptDownload = true;
    const r = await runDailyBackup(E, userId, NOW);
    expect(r.ok).toBe(false);
    expect((await E.DB.prepare("SELECT status FROM backup_manifests WHERE user_id = ? AND kind = 'daily'").bind(userId).first<{ status: string }>())!.status).toBe('failed');
    const notes = await (await api(cookie, '/notifications')).json<{ items: { title: string; level: string }[] }>();
    expect(notes.items[0]).toMatchObject({ level: 'error', title: 'バックアップに失敗しました' });
    const ret = await runRetention(E, userId, NOW);
    expect(ret).toMatchObject({ purged: 0, skipped: '検証済みの新しいバックアップがありません' });
    expect((await pullAll(cookie)).changes.filter((c) => c.deleted)).toHaveLength(0);
  });

  it('権限取り消し時は通知して停止（繰り返しの警告は1件にまとめる）', async () => {
    const { cookie, userId } = await login();
    fg.fail.revoked = true;
    expect((await runDailyBackup(E, userId, NOW)).ok).toBe(false);
    expect((await runDailyBackup(E, userId, NOW + 1)).ok).toBe(false);
    const notes = await (await api(cookie, '/notifications')).json<{ items: { title: string }[] }>();
    expect(notes.items.map((n) => n.title)).toEqual(['Googleドライブの権限がありません']);
  });

  it('容量が少なければ警告', async () => {
    const { cookie, userId } = await login();
    fg.fail.quotaUsage = 950;
    await runDailyBackup(E, userId, NOW);
    const notes = await (await api(cookie, '/notifications')).json<{ items: { title: string }[] }>();
    expect(notes.items.map((n) => n.title)).toContain('Googleドライブの空き容量が少なくなっています');
  });
});

describe('期限削除のデータ保護ゲート', () => {
  it('検証済みバックアップがなければ1件も消さない', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    expect(await runRetention(E, userId, NOW)).toMatchObject({ purged: 0 });
  });

  it('アーカイブを保存・検証してから、期限の来たものだけを削除する', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    expect((await runDailyBackup(E, userId, NOW)).ok).toBe(true);
    const r = await runRetention(E, userId, NOW);
    expect(r.purged).toBe(3); // 40日前のタスク・そのサブタスク・特則の夜勤
    expect(r.occurrences).toBeGreaterThanOrEqual(4); // 30日より前の授業の各回
    const changes = (await pullAll(cookie)).changes;
    const byId = Object.fromEntries(changes.map((c) => [c.id, c]));
    expect(byId.old).toMatchObject({ deleted: true, reason: 'purge' });
    expect(byId['sub-old']).toMatchObject({ deleted: true, reason: 'purge' });
    expect(byId.night).toMatchObject({ deleted: true, reason: 'purge' });
    expect(byId.recent!.deleted).toBe(false);
    expect(byId.hold!.deleted).toBe(false); // 提出期限のみの課題は保留
    const series = byId.series!.record as unknown as CalEvent;
    expect(byId.series!.deleted).toBe(false); // 継続中のマスターは残す
    expect(series.exceptions.filter((x) => x.kind === 'archived').length).toBe(r.occurrences);
    // Drive のアーカイブに削除したデータが入っている
    const archive = [...fg.files.values()].find((f) => f.name.startsWith('MyTime-archive-'));
    expect(archive!.content).toContain('"40日前"');
    expect(archive!.content).toContain('"夜勤"');
    const ledger = await E.DB.prepare('SELECT COUNT(*) AS n FROM purge_ledger WHERE user_id = ?').bind(userId).first<{ n: number }>();
    expect(ledger!.n).toBe(3);
  });

  it('アーカイブの保存に失敗したら1件も消さずに通知', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    expect((await runDailyBackup(E, userId, NOW)).ok).toBe(true);
    fg.fail.upload = true;
    const r = await runRetention(E, userId, NOW);
    expect(r).toMatchObject({ purged: 0, skipped: 'アーカイブ失敗' });
    expect((await pullAll(cookie)).changes.filter((c) => c.deleted)).toHaveLength(0);
    const notes = await (await api(cookie, '/notifications')).json<{ items: { title: string }[] }>();
    expect(notes.items.map((n) => n.title)).toContain('過去データのアーカイブに失敗しました');
  });

  it('同じ処理を二度実行しても二重に削除・記録しない', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    await runDailyBackup(E, userId, NOW);
    await runRetention(E, userId, NOW);
    const again = await runRetention(E, userId, NOW + 1000);
    expect(again.purged).toBe(0);
    expect((await E.DB.prepare('SELECT COUNT(*) AS n FROM purge_ledger').first<{ n: number }>())!.n).toBe(3);
  });
});

describe('期間指定の復元（閲覧を終了するまで残す）', () => {
  it('アーカイブから通常画面へ戻し、閲覧中は再削除せず、閲覧終了で外す（Drive の原本は残る）', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    await runDailyBackup(E, userId, NOW);
    await runRetention(E, userId, NOW);
    const before = await pullAll(cookie);
    const res = await (await api(cookie, '/restore', { method: 'POST', body: JSON.stringify({ from: NOW - 45 * DAY, to: NOW - 35 * DAY }) })).json<{ sessionId: string; restored: number }>();
    expect(res.restored).toBeGreaterThanOrEqual(2); // 40日前のタスクと、その期間の授業の回
    const restored = (await pullAll(cookie, before.cursor)).changes;
    expect(restored.find((c) => c.id === 'old')).toMatchObject({ deleted: false, restoredSessionId: res.sessionId });
    // 閲覧中に期限処理が走っても再削除しない
    await runDailyBackup(E, userId, NOW + 1000);
    const again = await runRetention(E, userId, NOW + 1000);
    expect(again.purged).toBe(0);
    const mid = await pullAll(cookie, before.cursor);
    expect(mid.changes.find((c) => c.id === 'old')!.deleted).toBe(false);
    // 閲覧を終了
    const end = await (await api(cookie, `/restore/${res.sessionId}/end`, { method: 'POST' })).json<{ removed: number }>();
    expect(end.removed).toBe(res.restored);
    const after = await pullAll(cookie, mid.cursor);
    expect(after.changes.find((c) => c.id === 'old')).toMatchObject({ deleted: true, reason: 'restore-end' });
    expect([...fg.files.values()].some((f) => f.name.startsWith('MyTime-archive-') && f.content.includes('"40日前"'))).toBe(true);
  });

  it('アーカイブが壊れていたら復元しない', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    await runDailyBackup(E, userId, NOW);
    await runRetention(E, userId, NOW);
    fg.fail.corruptDownload = true;
    const r = await api(cookie, '/restore', { method: 'POST', body: JSON.stringify({ from: NOW - 45 * DAY, to: NOW - 35 * DAY }) });
    expect(r.status).toBe(502);
    expect(await r.json()).toMatchObject({ error: expect.stringContaining('検証') });
  });
});

describe('バックアップ管理', () => {
  it('古い日次は削除できるが、アーカイブと最新の検証済みは削除できない', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    const d1 = await runDailyBackup(E, userId, NOW - DAY);
    const d2 = await runDailyBackup(E, userId, NOW);
    await runRetention(E, userId, NOW);
    const list = await (await api(cookie, '/backups')).json<{ items: { id: string; kind: string }[] }>();
    const archive = list.items.find((i) => i.kind === 'archive')!;
    expect((await api(cookie, `/backups/${archive.id}`, { method: 'DELETE' })).status).toBe(409);
    expect((await api(cookie, `/backups/${d2.manifestId}`, { method: 'DELETE' })).status).toBe(409);
    expect((await api(cookie, `/backups/${d1.manifestId}`, { method: 'DELETE' })).status).toBe(200);
  });
});

describe('Web Push と定期実行', () => {
  async function subscriber() {
    const kp = (await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits'])) as CryptoKeyPair;
    const pub = new Uint8Array((await crypto.subtle.exportKey('raw', kp.publicKey)) as ArrayBuffer);
    const auth = crypto.getRandomValues(new Uint8Array(16));
    return { kp, p256dh: b64url(pub), auth: b64url(auth), authRaw: auth, pub };
  }

  it('RFC 8291 で暗号化した本文を受信側の鍵で復号できる', async () => {
    const s = await subscriber();
    const body = await encryptPayload('{"title":"テスト"}', s.p256dh, s.auth);
    const salt = body.slice(0, 16);
    const asPub = body.slice(21, 21 + body[20]!);
    const ct = body.slice(21 + body[20]!);
    const hk = async (sa: Uint8Array, ikm: Uint8Array, info: string | Uint8Array, len: number) =>
      new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: sa, info: typeof info === 'string' ? new TextEncoder().encode(info) : info }, await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']), len * 8));
    const asKey = await crypto.subtle.importKey('raw', asPub, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
    const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', $public: asKey, public: asKey } as unknown as SubtleCryptoDeriveKeyAlgorithm, s.kp.privateKey, 256));
    const info = new Uint8Array([...new TextEncoder().encode('WebPush: info\0'), ...s.pub, ...asPub]);
    const ikm = await hk(s.authRaw, ecdh, info, 32);
    const cek = await hk(salt, ikm, 'Content-Encoding: aes128gcm\0', 16);
    const nonce = await hk(salt, ikm, 'Content-Encoding: nonce\0', 12);
    const pt = new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: nonce }, await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['decrypt']), ct));
    expect(new TextDecoder().decode(pt.slice(0, -1))).toBe('{"title":"テスト"}');
    expect(pt.at(-1)).toBe(2);
  });

  it('VAPID の署名を公開鍵で検証できる', async () => {
    const kp = (await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const pub = b64url((await crypto.subtle.exportKey('raw', kp.publicKey)) as ArrayBuffer);
    const jwk = JSON.stringify(await crypto.subtle.exportKey('jwk', kp.privateKey));
    const h = await vapidAuthorization('https://push.example.com/abc', pub, jwk, 'mailto:a@b.c', NOW);
    const [, jwt, k] = /^vapid t=([^,]+), k=(.+)$/.exec(h)!;
    expect(k).toBe(pub);
    const [hh, pp, ss] = jwt!.split('.');
    const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, kp.publicKey, fromB64url(ss!), new TextEncoder().encode(`${hh}.${pp}`));
    expect(ok).toBe(true);
    expect(JSON.parse(new TextDecoder().decode(fromB64url(pp!)))).toMatchObject({ aud: 'https://push.example.com', sub: 'mailto:a@b.c' });
  });

  it('未開始タスクの通知を1回だけ送る（同じ通知は再送しない）', async () => {
    const kp = (await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
    const envP = { ...E, VAPID_PUBLIC_KEY: b64url((await crypto.subtle.exportKey('raw', kp.publicKey)) as ArrayBuffer), VAPID_PRIVATE_JWK: JSON.stringify(await crypto.subtle.exportKey('jwk', kp.privateKey)) };
    const { cookie } = await login();
    const s = await subscriber();
    await api(cookie, '/push/subscribe', { method: 'POST', body: JSON.stringify({ endpoint: 'https://push.example.com/sub1', keys: { p256dh: s.p256dh, auth: s.auth } }) });
    const t = makeTask({ title: 'レポート', plannedStart: NOW - 6 * 60_000, plannedEnd: NOW + 3_600_000 }, NOW - DAY);
    await push(cookie, [putOp('task', t)]);
    let received = 0;
    fetchMock.get('https://push.example.com').intercept({ path: '/sub1', method: 'POST' }).reply(() => {
      received += 1;
      return { statusCode: 201, data: '' };
    }).persist();
    expect((await runNotifications(envP as Env, NOW)).sent).toBe(1);
    expect((await runNotifications(envP as Env, NOW + 60_000)).sent).toBe(0);
    expect(received).toBe(1);
  });

  it('毎日のCron：バックアップ成功後にだけ期限処理する', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    fg.fail.upload = true;
    await scheduled('0 13 * * *', E, NOW);
    expect((await pullAll(cookie)).changes.filter((c) => c.deleted)).toHaveLength(0);
    fg.fail.upload = false;
    await scheduled('0 13 * * *', E, NOW + 60_000);
    expect((await pullAll(cookie)).changes.filter((c) => c.deleted).length).toBe(3);
    expect(userId).toBeTruthy();
  });
});

describe('タスクの型', () => {
  it('Task の既定値はスキーマ検証を通る', async () => {
    const { cookie } = await login();
    const t: Task = makeTask({ title: '既定' }, NOW);
    expect((await push(cookie, [putOp('task', t)])).results[0]!.status).toBe('applied');
  });
});
