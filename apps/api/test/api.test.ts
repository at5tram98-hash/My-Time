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

/** ログインを開始し、Google の同意画面までを済ませた状態（ブラウザの印 Cookie と state・認可コード）を返す */
async function beginLogin(sub: string, now?: number) {
  const r1 = await SELF.fetch('http://localhost:8787/api/auth/login', { redirect: 'manual', headers: now ? { 'x-mytime-now': String(now) } : {} });
  expect(r1.status).toBe(302);
  const loc = new URL(r1.headers.get('location')!);
  const browserCookie = r1.headers.get('set-cookie')!.split(';')[0]!;
  expect(browserCookie).toMatch(/^mt_login=/);
  expect(r1.headers.get('set-cookie')).toMatch(/HttpOnly/i);
  const code = `code-${sub}-${crypto.randomUUID().slice(0, 6)}`;
  await fg.addCode(code, { sub, email: `${sub}@example.com`, name: 'ゆうき' });
  return { loc, browserCookie, state: loc.searchParams.get('state')!, code };
}

const callback = (state: string, code: string, cookie: string, now?: number) =>
  SELF.fetch(`http://localhost:8787/api/auth/callback?state=${state}&code=${code}`, { redirect: 'manual', headers: { ...(cookie ? { cookie } : {}), ...(now ? { 'x-mytime-now': String(now) } : {}) } });

async function login(sub = 'g-1'): Promise<{ cookie: string; userId: string }> {
  const { loc, browserCookie, state, code } = await beginLogin(sub);
  expect(loc.searchParams.get('code_challenge_method')).toBe('S256');
  expect(loc.searchParams.get('scope')).toContain('drive.file');
  expect(loc.searchParams.get('scope')).not.toMatch(/\/auth\/drive(\s|$)/);
  const r2 = await callback(state, code, browserCookie);
  expect(r2.headers.get('location')).toBe('/?login=ok');
  const set = r2.headers.getSetCookie().find((x) => x.startsWith('mt_session='))!;
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

  const sessionSet = (r: Response) => r.headers.getSetCookie().some((x) => x.startsWith('mt_session='));

  it('存在しない state は拒否', async () => {
    const r = await callback('bogus', 'x', 'mt_login=whatever');
    expect(r.headers.get('location')).toMatch(/login=error/);
    expect(sessionSet(r)).toBe(false);
  });

  it('ログイン CSRF：攻撃者の callback URL を被害者のブラウザで開かせても、被害者のセッションは切り替わらない', async () => {
    const victim = await login('g-victim');
    // 攻撃者が自分のブラウザでログインを開始し、同意後の callback URL を手に入れる
    const evil = await beginLogin('g-evil');
    // 被害者のブラウザ（ログイン開始の印を持たない／自分の別の印を持つ）で開く
    const viaLink = await callback(evil.state, evil.code, victim.cookie);
    expect(viaLink.headers.get('location')).toMatch(/login=error/);
    expect(sessionSet(viaLink)).toBe(false);
    const own = await beginLogin('g-victim');
    const mixed = await callback(evil.state, evil.code, `${victim.cookie}; ${own.browserCookie}`);
    expect(mixed.headers.get('location')).toMatch(/login=error/);
    expect(sessionSet(mixed)).toBe(false);
    // 被害者は自分のアカウントのまま。攻撃者のユーザーは作られていない
    expect(await (await api(victim.cookie, '/me')).json()).toMatchObject({ user: { email: 'g-victim@example.com' } });
    expect(await E.DB.prepare("SELECT id FROM users WHERE google_sub = 'g-evil'").first()).toBeNull();
    // 一度失敗した state は消費済み：攻撃者自身のブラウザでも、もう使えない
    const retry = await callback(evil.state, evil.code, evil.browserCookie);
    expect(retry.headers.get('location')).toMatch(/login=error/);
  });

  it('state の再利用・期限切れ・Cookie なしは拒否', async () => {
    const a = await beginLogin('g-1');
    expect((await callback(a.state, a.code, a.browserCookie)).headers.get('location')).toBe('/?login=ok');
    const reuse = await callback(a.state, a.code, a.browserCookie);
    expect(reuse.headers.get('location')).toMatch(/login=error/);
    expect(sessionSet(reuse)).toBe(false);

    const t0 = Date.now();
    const b = await beginLogin('g-1', t0);
    const late = await callback(b.state, b.code, b.browserCookie, t0 + 11 * 60_000);
    expect(late.headers.get('location')).toMatch(/login=error/);
    expect(sessionSet(late)).toBe(false);

    const c2 = await beginLogin('g-1');
    const noCookie = await callback(c2.state, c2.code, '');
    expect(noCookie.headers.get('location')).toMatch(/login=error/);
    expect(sessionSet(noCookie)).toBe(false);
  });

  it('同じブラウザで別アカウントにログインし直すと、以前のセッションは無効になる', async () => {
    const a = await login('g-a');
    const b = await beginLogin('g-b');
    const r = await callback(b.state, b.code, `${a.cookie}; ${b.browserCookie}`);
    expect(r.headers.get('location')).toBe('/?login=ok');
    expect((await api(a.cookie, '/me')).status).toBe(401);
  });

  it('端末の保存領域のアカウントがログイン中と違う送受信は拒否（別アカウントのデータを混ぜない）', async () => {
    const a = await login('g-a');
    const b = await login('g-b');
    const t = makeTask({ title: 'Aのデータ' }, NOW);
    const body = JSON.stringify({ ops: [putOp('task', t)] });
    // Bでログイン中のブラウザから、Aの領域のデータとして送ってきた
    const r = await api(b.cookie, '/sync/push', { method: 'POST', body, headers: { 'x-mytime-account': a.userId } });
    expect(r.status).toBe(409);
    expect(await r.json()).toMatchObject({ code: 'account-mismatch' });
    expect((await api(b.cookie, '/sync/pull?cursor=0', { headers: { 'x-mytime-account': a.userId } })).status).toBe(409);
    expect((await pullAll(b.cookie)).changes).toHaveLength(0);
    expect((await api(a.cookie, '/sync/push', { method: 'POST', body, headers: { 'x-mytime-account': a.userId } })).status).toBe(200);
  });

  it('ログアウトは独自ヘッダー必須（他サイトからの強制ログアウトを防ぐ）', async () => {
    const { cookie } = await login();
    const r = await SELF.fetch('http://localhost:8787/api/auth/logout', { method: 'POST', headers: { cookie } });
    expect(r.status).toBe(403);
    expect((await api(cookie, '/me')).status).toBe(200);
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
  // 提出期限だけの課題：作成日から30日（90日前に作成→期限切れ／10日前に作成→残す）
  const asgOld = makeTask({ id: 'asg-old', title: '提出期限のみ（古い）', special: 'assignment', assignment: { content: '', submitMethod: '', submitTo: '', deadline: NOW + 5 * DAY } }, NOW - 90 * DAY);
  const asgNew = makeTask({ id: 'asg-new', title: '提出期限のみ（新しい）', special: 'assignment', assignment: { content: '', submitMethod: '', submitTo: '', deadline: NOW - 60 * DAY } }, NOW - 10 * DAY);
  const night = makeEvent({ id: 'night', title: '夜勤', calendarId: 'cal-job', start: Date.parse('2026-11-29T22:00:00+09:00'), end: Date.parse('2026-11-30T06:00:00+09:00'), hideAfterEnd: true }, NOW - 2 * DAY);
  const series = makeEvent({ id: 'series', title: '毎週の授業', calendarId: 'cal-class', start: NOW - 60 * DAY, end: NOW - 60 * DAY + 5_400_000, recurrence: { freq: 'weekly', interval: 1, byWeekday: null, until: null } }, NOW - 60 * DAY);
  const oldSub = { id: 'sub-old', taskId: 'old', title: '章1', done: true, completedAt: NOW - 40 * DAY, order: 0, createdAt: NOW - 41 * DAY, updatedAt: NOW - 40 * DAY };
  await push(cookie, [putOp('task', old), putOp('task', recent), putOp('task', asgOld), putOp('task', asgNew), putOp('event', night), putOp('event', series), putOp('subtask', oldSub)]);
}

describe('削除済みデータの復活防止（tombstone は端末の更新日時より優先）', () => {
  const delOp = (entity: SyncOp['entity'], id: string, baseVersion: number, at: number): SyncOp => ({ opId: `del-${crypto.randomUUID()}`, entity, entityId: id, op: 'delete', record: null, baseVersion, clientUpdatedAt: at });
  const row = (userId: string, id: string) => E.DB.prepare("SELECT version, deleted, delete_reason, data FROM records WHERE user_id = ? AND entity = 'task' AND id = ?").bind(userId, id).first<{ version: number; deleted: number; delete_reason: string; data: string | null }>();

  it('ユーザー削除後、古い baseVersion・新しい updatedAt の put でも再作成しない', async () => {
    const { cookie, userId } = await login();
    const t = makeTask({ title: '消したタスク' }, NOW);
    await push(cookie, [putOp('task', t)]);
    expect((await push(cookie, [delOp('task', t.id, 1, NOW + 1000)])).results[0]).toMatchObject({ status: 'applied', version: 2 });
    // 削除を知らない別端末が、削除より後の時刻で編集して送ってきた
    const late = await push(cookie, [putOp('task', { ...t, title: '別端末の編集', updatedAt: NOW + 99_000 }, 1)]);
    expect(late.results[0]).toMatchObject({ status: 'conflict', serverDeleted: true, deleteReason: 'user', serverRecord: null });
    // baseVersion を最新に合わせても同じ（put では復活できない）
    const forged = await push(cookie, [putOp('task', { ...t, title: '最新版に見せかけ', updatedAt: NOW + 99_500 }, 2)]);
    expect(forged.results[0]).toMatchObject({ status: 'conflict', serverDeleted: true });
    expect(await row(userId, t.id)).toMatchObject({ deleted: 1, delete_reason: 'user', data: null, version: 2 });
    // 削除の再送は冪等（版は増えない）
    expect((await push(cookie, [delOp('task', t.id, 1, NOW + 100_000)])).results[0]).toMatchObject({ status: 'applied', version: 2 });
    const log = await E.DB.prepare("SELECT COUNT(*) AS n FROM operation_log WHERE user_id = ? AND action = 'put-refused'").bind(userId).first<{ n: number }>();
    expect(log!.n).toBe(2);
  });

  it('オフラインだった端末が期限削除後に再接続しても、記録は復活しない', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    const oldRec = (await pullAll(cookie)).changes.find((c) => c.id === 'old')!;
    // 端末Bはこの時点（version 1）を持ったままオフラインに
    expect((await runDailyBackup(E, userId, NOW)).ok).toBe(true);
    await runRetention(E, userId, NOW);
    expect(await row(userId, 'old')).toMatchObject({ deleted: 1, delete_reason: 'purge' });
    // 端末Bが再接続：期限削除より後の時刻で編集した内容を、古い baseVersion で送る
    const edited = { ...(oldRec.record as unknown as Task), title: 'オフラインで編集', updatedAt: NOW + 5 * DAY };
    const r = await push(cookie, [putOp('task', edited, oldRec.version)]);
    expect(r.results[0]).toMatchObject({ status: 'conflict', serverDeleted: true, deleteReason: 'purge' });
    expect(await row(userId, 'old')).toMatchObject({ deleted: 1, delete_reason: 'purge', data: null });
    // 次の日の期限処理・バックアップでも復活しない（現役データに含まれない）
    await runDailyBackup(E, userId, NOW + DAY);
    const latest = [...fg.files.values()].filter((f) => f.name.startsWith('MyTime-daily-')).at(-1)!;
    expect(latest.content).not.toContain('オフラインで編集');
  });

  it('復元閲覧の終了で外れた記録も put では戻らない。復元は /restore API だけ', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    await runDailyBackup(E, userId, NOW);
    await runRetention(E, userId, NOW);
    const res = await (await api(cookie, '/restore', { method: 'POST', body: JSON.stringify({ from: NOW - 45 * DAY, to: NOW - 35 * DAY }) })).json<{ sessionId: string }>();
    const viewing = (await pullAll(cookie)).changes.find((c) => c.id === 'old')!;
    expect(viewing).toMatchObject({ deleted: false, restoredSessionId: res.sessionId });
    // 閲覧中の編集は受け付けるが、復元中の印は残る（編集しただけで恒久的に戻ったことにはしない）
    const ed = await push(cookie, [putOp('task', { ...(viewing.record as unknown as Task), title: '閲覧中に編集', updatedAt: NOW + 1000 }, viewing.version)]);
    expect(ed.results[0]!.status).toBe('applied');
    const mark = await E.DB.prepare("SELECT restored_session_id FROM records WHERE user_id = ? AND id = 'old'").bind(userId).first<{ restored_session_id: string }>();
    expect(mark!.restored_session_id).toBe(res.sessionId);
    await api(cookie, `/restore/${res.sessionId}/end`, { method: 'POST' });
    expect(await row(userId, 'old')).toMatchObject({ deleted: 1, delete_reason: 'restore-end' });
    const back = await push(cookie, [putOp('task', { ...(viewing.record as unknown as Task), title: '戻そうとする', updatedAt: NOW + 9 * DAY }, viewing.version + 1)]);
    expect(back.results[0]).toMatchObject({ status: 'conflict', serverDeleted: true, deleteReason: 'restore-end' });
    // 復元 API なら戻せる
    const again = await (await api(cookie, '/restore', { method: 'POST', body: JSON.stringify({ from: NOW - 45 * DAY, to: NOW - 35 * DAY }) })).json<{ restored: number }>();
    expect(again.restored).toBeGreaterThan(0);
    expect(await row(userId, 'old')).toMatchObject({ deleted: 0 });
  });

  it('期限削除と同時に古い端末の送信が来ても、削除後の記録を上書きしない（条件付き更新）', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    const oldRec = (await pullAll(cookie)).changes.find((c) => c.id === 'old')!;
    expect((await runDailyBackup(E, userId, NOW)).ok).toBe(true);
    // 期限削除と、古い端末の送信（期限削除前の版を見た put）を同時に走らせる
    const edited = { ...(oldRec.record as unknown as Task), title: '同時に編集', updatedAt: NOW + 2000 };
    const [ret, pushed] = await Promise.all([runRetention(E, userId, NOW), push(cookie, [putOp('task', edited, oldRec.version)])]);
    const final = await row(userId, 'old');
    const r = pushed.results[0]!;
    if (final!.deleted === 1) {
      // 削除が勝った：put は反映されず、tombstone として返る（または再送待ち）
      expect(['conflict', 'retry']).toContain(r.status);
      expect(final!.data).toBeNull();
    } else {
      // 編集が先に入った：期限削除は版が変わったので見送る（次回、編集後の内容でバックアップしてから判断）
      expect(r.status).toBe('applied');
      expect(ret.purged).toBeLessThan(4);
      expect(JSON.parse(final!.data!).title).toBe('同時に編集');
    }
  });
});

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
    expect(JSON.parse(m!.counts)).toMatchObject({ task: 4, event: 2, subtask: 1 });
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
    expect(r.purged).toBe(4); // 40日前のタスク・そのサブタスク・作成から90日の課題・特則の夜勤
    expect(r.occurrences).toBeGreaterThanOrEqual(4); // 30日より前の授業の各回
    const changes = (await pullAll(cookie)).changes;
    const byId = Object.fromEntries(changes.map((c) => [c.id, c]));
    expect(byId.old).toMatchObject({ deleted: true, reason: 'purge' });
    expect(byId['sub-old']).toMatchObject({ deleted: true, reason: 'purge' });
    expect(byId.night).toMatchObject({ deleted: true, reason: 'purge' });
    expect(byId.recent!.deleted).toBe(false);
    expect(byId['asg-old']).toMatchObject({ deleted: true, reason: 'purge' }); // 提出期限のみでも作成日から30日
    expect(byId['asg-new']!.deleted).toBe(false);
    const series = byId.series!.record as unknown as CalEvent;
    expect(byId.series!.deleted).toBe(false); // 継続中のマスターは残す
    expect(series.exceptions.filter((x) => x.kind === 'archived').length).toBe(r.occurrences);
    // Drive のアーカイブに削除したデータが入っている
    const archive = [...fg.files.values()].find((f) => f.name.startsWith('MyTime-archive-'));
    expect(archive!.content).toContain('"40日前"');
    expect(archive!.content).toContain('"夜勤"');
    const ledger = await E.DB.prepare('SELECT COUNT(*) AS n FROM purge_ledger WHERE user_id = ?').bind(userId).first<{ n: number }>();
    expect(ledger!.n).toBe(4);
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
    expect((await E.DB.prepare('SELECT COUNT(*) AS n FROM purge_ledger').first<{ n: number }>())!.n).toBe(4);
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

describe('バックアップの安全性（設定・操作ログ・復元試験・期限削除の切り替え）', () => {
  it('日次バックアップに設定・操作ログ・削除済みの印を含め、読み戻した内容から復元すると現在のデータと一致する', async () => {
    const { cookie, userId } = await login();
    await api(cookie, '/settings', { method: 'PUT', body: JSON.stringify({ theme: 'dark', suggestFromHour: 8 }) });
    await seedForRetention(cookie);
    const gone = makeTask({ id: 'gone', title: '消した' }, NOW);
    await push(cookie, [putOp('task', gone)]);
    await push(cookie, [{ opId: 'del-gone', entity: 'task', entityId: 'gone', op: 'delete', record: null, baseVersion: 1, clientUpdatedAt: NOW + 1 }]);
    const b = await runDailyBackup(E, userId, NOW);
    expect(b.ok).toBe(true);
    const file = [...fg.files.values()].find((f) => f.name.startsWith('MyTime-daily-'))!;
    const body = JSON.parse(file.content) as { schemaVersion: number; tables: Record<string, Record<string, unknown>[]> };
    expect(body.schemaVersion).toBe(3);
    expect(body.tables.settings![0]).toMatchObject({ key: 'app', theme: 'dark', suggestFromHour: 8 });
    expect(body.tables.operationLog!.length).toBeGreaterThan(5);
    expect(body.tables.tombstones).toEqual([expect.objectContaining({ entity: 'task', id: 'gone', reason: 'user' })]);
    // 復元試験：読み戻し → 検証 → 復元した記録と現在のデータを1件ずつ比べる
    const drill = await (await api(cookie, `/backups/${b.manifestId}/drill`, { method: 'POST' })).json<{ ok: boolean; matched: number; changed: string[]; extras: { settings: number; tombstones: number } }>();
    expect(drill).toMatchObject({ ok: true, changed: [], extras: { settings: 1, tombstones: 1 } });
    expect(drill.matched).toBe(7); // タスク4・サブタスク1・予定2（現役の記録すべて）
    // バックアップ後に変更すると、差分として検出される（データは書き換えない）
    const recent = (await pullAll(cookie)).changes.find((c) => c.id === 'recent')!;
    await push(cookie, [putOp('task', { ...(recent.record as unknown as Task), title: '後で変更', updatedAt: NOW + 5000 }, recent.version)]);
    const drill2 = await (await api(cookie, `/backups/${b.manifestId}/drill`, { method: 'POST' })).json<{ ok: boolean; changed: string[] }>();
    expect(drill2).toMatchObject({ ok: false, changed: ['task:recent'] });
  });

  it('アーカイブから戻した内容は、削除する直前の内容と完全に一致する', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    const before = new Map((await pullAll(cookie)).changes.map((c) => [c.id, c.record]));
    expect((await runDailyBackup(E, userId, NOW)).ok).toBe(true);
    const r = await runRetention(E, userId, NOW);
    const drill = await (await api(cookie, `/backups/${r.manifestId}/drill`, { method: 'POST' })).json<{ ok: boolean; matched: number }>();
    expect(drill.ok).toBe(true);
    const res = await (await api(cookie, '/restore', { method: 'POST', body: JSON.stringify({ from: NOW - 100 * DAY, to: NOW }) })).json<{ restored: number }>();
    expect(res.restored).toBeGreaterThanOrEqual(4);
    const after = new Map((await pullAll(cookie)).changes.filter((c) => c.restoredSessionId).map((c) => [c.id, c.record]));
    for (const id of ['old', 'sub-old', 'asg-old', 'night']) expect(after.get(id)).toEqual(before.get(id));
  });

  it('RETENTION_MODE：未設定・off は削除しない、dry-run は件数だけ知らせる、on で実行', async () => {
    const { cookie, userId } = await login();
    await seedForRetention(cookie);
    expect((await runDailyBackup(E, userId, NOW)).ok).toBe(true);
    const deletedCount = async () => (await pullAll(cookie)).changes.filter((c) => c.deleted).length;
    expect(await runRetention({ ...E, RETENTION_MODE: undefined }, userId, NOW)).toMatchObject({ purged: 0, skipped: expect.stringContaining('停止') });
    expect(await runRetention({ ...E, RETENTION_MODE: 'off' }, userId, NOW)).toMatchObject({ purged: 0 });
    expect(await runRetention({ ...E, RETENTION_MODE: 'すぐ消す' }, userId, NOW)).toMatchObject({ purged: 0 }); // 不明な値は off 扱い
    const dry = await runRetention({ ...E, RETENTION_MODE: 'dry-run' }, userId, NOW);
    expect(dry).toMatchObject({ purged: 0, skipped: expect.stringContaining('試運転（対象 4件') });
    expect(await deletedCount()).toBe(0);
    expect([...fg.files.values()].some((f) => f.name.startsWith('MyTime-archive-'))).toBe(false);
    const n = await (await api(cookie, '/notifications')).json<{ items: { title: string }[] }>();
    expect(n.items.map((x) => x.title)).toContain('期限削除の試運転');
    expect((await runRetention({ ...E, RETENTION_MODE: 'on' }, userId, NOW)).purged).toBe(4);
    expect(await deletedCount()).toBe(4);
  });

  it('本番の初期設定（wrangler.toml）では期限削除は off', async () => {
    const cfg = await (await SELF.fetch('http://localhost:8787/api/config')).json<{ retentionMode: string }>();
    expect(['on', 'off', 'dry-run']).toContain(cfg.retentionMode);
    const toml = (await import('../wrangler.toml?raw')).default as string;
    expect(toml).toMatch(/^RETENTION_MODE = "off"$/m);
  });

  it('古い端末の再接続 × 同期の衝突 × 期限削除の同時実行：削除は復活せず、競合は新しい方、バックアップと一致', async () => {
    const a = await login('g-mix');
    await seedForRetention(a.cookie);
    const snap = new Map((await pullAll(a.cookie)).changes.map((c) => [c.id, c]));
    expect((await runDailyBackup(E, a.userId, NOW)).ok).toBe(true);
    // 端末A（オンライン）：recent を新しく編集
    const recentA = { ...(snap.get('recent')!.record as unknown as Task), title: 'Aの編集', updatedAt: NOW + 10_000 };
    // 端末B（古い・オフラインだった）：recent を古い時刻で、old（期限切れ）を新しい時刻で編集
    const recentB = { ...(snap.get('recent')!.record as unknown as Task), title: 'Bの古い編集', updatedAt: NOW + 1000 };
    const oldB = { ...(snap.get('old')!.record as unknown as Task), title: 'Bの編集（期限切れの記録）', updatedAt: NOW + 20_000 };
    const [ret, pa, pb] = await Promise.all([
      runRetention(E, a.userId, NOW),
      push(a.cookie, [putOp('task', recentA, snap.get('recent')!.version)]),
      push(a.cookie, [putOp('task', recentB, snap.get('recent')!.version), putOp('task', oldB, snap.get('old')!.version)]),
    ]);
    const final = new Map((await pullAll(a.cookie)).changes.map((c) => [c.id, c]));
    // recent：新しい方（A）が残る（どちらが先に届いても）
    expect((final.get('recent')!.record as unknown as Task).title).toBe('Aの編集');
    expect([pa.results[0]!.status, pb.results[0]!.status]).toContain('applied');
    // old：期限削除が先なら削除のまま（B の編集で復活しない）。B が先なら、版が変わったので今回は削除を見送る
    const old = final.get('old')!;
    if (old.deleted) {
      expect(old.reason).toBe('purge');
      expect(['conflict', 'retry']).toContain(pb.results[1]!.status);
      // 以後、B が何度送っても戻らない
      const again = await push(a.cookie, [putOp('task', { ...oldB, updatedAt: NOW + 30_000 }, old.version)]);
      expect(again.results[0]).toMatchObject({ status: 'conflict', serverDeleted: true });
    } else {
      expect((old.record as unknown as Task).title).toBe('Bの編集（期限切れの記録）');
      expect(ret.purged).toBeLessThan(4);
    }
    // 何が起きても、次の日次バックアップは現在のデータと完全一致する
    const b2 = await runDailyBackup(E, a.userId, NOW + 60_000);
    const drill = await (await api(a.cookie, `/backups/${b2.manifestId}/drill`, { method: 'POST' })).json<{ ok: boolean }>();
    expect(drill.ok).toBe(true);
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
    expect((await pullAll(cookie)).changes.filter((c) => c.deleted).length).toBe(4);
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
