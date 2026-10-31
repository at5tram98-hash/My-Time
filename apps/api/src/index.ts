import { Hono } from 'hono';
import { googleConfigured, pushConfigured, applyUserZone, type AppBindings, type Env } from './env';
import { authRoutes, requireUser } from './routes/auth';
import { syncRoutes } from './routes/sync';
import { endRestore, runDailyBackup, runRetention, startRestore, driveFor } from './jobs/backup';
import { runNotifications } from './jobs/notify';
import { newId } from './lib/crypto';

export const app = new Hono<AppBindings>().basePath('/api');

app.use('*', async (c, next) => {
  applyUserZone(c.env);
  // テスト専用：ALLOW_TEST_CLOCK=1 のときだけ時刻を差し替え可能（本番の設定には含めない）
  const t = c.env.ALLOW_TEST_CLOCK === '1' ? Number(c.req.header('x-mytime-now')) : NaN;
  c.set('now', Number.isFinite(t) && t > 0 ? t : Date.now());
  await next();
  c.header('cache-control', 'no-store');
});

app.get('/config', (c) => c.json({ googleConfigured: googleConfigured(c.env), pushPublicKey: pushConfigured(c.env) ? c.env.VAPID_PUBLIC_KEY : null, apiVersion: 2 }));

app.route('/auth', authRoutes);

const api = new Hono<AppBindings>();
api.use('*', requireUser);

api.get('/me', async (c) => {
  const u = await c.env.DB.prepare('SELECT id, email, name FROM users WHERE id = ?').bind(c.get('userId')).first<{ id: string; email: string; name: string }>();
  const g = await c.env.DB.prepare('SELECT scope, revoked_at FROM oauth_grants WHERE user_id = ?').bind(c.get('userId')).first<{ scope: string; revoked_at: number | null }>();
  return c.json({ user: u, drive: { connected: Boolean(g && !g.revoked_at && g.scope.includes('drive.file')) } });
});

api.route('/sync', syncRoutes);

api.get('/notifications', async (c) => {
  const rows = await c.env.DB.prepare('SELECT id, level, kind, title, body, created_at, read_at, resolved_at FROM notifications WHERE user_id = ? ORDER BY created_at DESC LIMIT 100').bind(c.get('userId')).all();
  return c.json({ items: rows.results });
});
api.post('/notifications/:id/read', async (c) => {
  await c.env.DB.prepare('UPDATE notifications SET read_at = ? WHERE id = ? AND user_id = ?').bind(c.get('now'), c.req.param('id'), c.get('userId')).run();
  return c.json({ ok: true });
});

api.get('/backups', async (c) => {
  const rows = await c.env.DB.prepare("SELECT id, kind, created_at, drive_file_name, bytes, counts, status, verified_at, error, range_from, range_to FROM backup_manifests WHERE user_id = ? AND status != 'deleted' ORDER BY created_at DESC LIMIT 200").bind(c.get('userId')).all();
  const pending = await c.env.DB.prepare('SELECT COUNT(*) AS n FROM restoration_sessions WHERE user_id = ? AND ended_at IS NULL').bind(c.get('userId')).first<{ n: number }>();
  return c.json({ items: rows.results, activeRestorations: pending?.n ?? 0 });
});
api.post('/backups/run', async (c) => {
  const r = await runDailyBackup(c.env, c.get('userId'), c.get('now'));
  return c.json(r, r.ok ? 200 : 502);
});
/** 古い日次バックアップの整理。アーカイブ（期限削除したデータの唯一の保管先）と最新の検証済みは消せない */
api.delete('/backups/:id', async (c) => {
  const id = c.req.param('id');
  const m = await c.env.DB.prepare('SELECT kind, drive_file_id, status FROM backup_manifests WHERE id = ? AND user_id = ?').bind(id, c.get('userId')).first<{ kind: string; drive_file_id: string | null; status: string }>();
  if (!m) return c.json({ error: '見つかりません' }, 404);
  if (m.kind !== 'daily') return c.json({ error: 'アーカイブは削除できません（期限削除したデータの保管先です）' }, 409);
  const latest = await c.env.DB.prepare("SELECT id FROM backup_manifests WHERE user_id = ? AND kind = 'daily' AND status = 'verified' ORDER BY verified_at DESC LIMIT 1").bind(c.get('userId')).first<{ id: string }>();
  if (latest?.id === id) return c.json({ error: '最新の検証済みバックアップは削除できません' }, 409);
  if (m.drive_file_id) {
    const drive = await driveFor(c.env, c.get('userId'), c.get('now'));
    if (!drive) return c.json({ error: 'Googleドライブに接続できません' }, 502);
    await drive.remove(m.drive_file_id).catch(() => undefined);
  }
  await c.env.DB.prepare("UPDATE backup_manifests SET status = 'deleted' WHERE id = ?").bind(id).run();
  return c.json({ ok: true });
});

api.post('/restore', async (c) => {
  const b = (await c.req.json().catch(() => ({}))) as { from?: number; to?: number };
  if (typeof b.from !== 'number' || typeof b.to !== 'number' || b.to <= b.from) return c.json({ error: '期間が不正です' }, 400);
  try {
    return c.json(await startRestore(c.env, c.get('userId'), b.from, b.to, c.get('now')));
  } catch (e) {
    return c.json({ error: e instanceof Error ? e.message : '復元に失敗しました' }, 502);
  }
});
api.get('/restore', async (c) => {
  const rows = await c.env.DB.prepare('SELECT id, range_from, range_to, created_at, restored_count FROM restoration_sessions WHERE user_id = ? AND ended_at IS NULL ORDER BY created_at DESC').bind(c.get('userId')).all();
  return c.json({ items: rows.results });
});
api.post('/restore/:id/end', async (c) => c.json({ removed: await endRestore(c.env, c.get('userId'), c.req.param('id'), c.get('now')) }));

api.post('/push/subscribe', async (c) => {
  const b = (await c.req.json().catch(() => ({}))) as { endpoint?: string; keys?: { p256dh?: string; auth?: string } };
  if (!b.endpoint?.startsWith('https://') || !b.keys?.p256dh || !b.keys.auth) return c.json({ error: '購読情報が不正です' }, 400);
  await c.env.DB.prepare('INSERT INTO push_subscriptions (id, user_id, endpoint, p256dh, auth, created_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(endpoint) DO UPDATE SET user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, failures = 0')
    .bind(newId(), c.get('userId'), b.endpoint, b.keys.p256dh, b.keys.auth, c.get('now'))
    .run();
  return c.json({ ok: true });
});
api.post('/push/unsubscribe', async (c) => {
  const b = (await c.req.json().catch(() => ({}))) as { endpoint?: string };
  await c.env.DB.prepare('DELETE FROM push_subscriptions WHERE endpoint = ? AND user_id = ?').bind(b.endpoint ?? '', c.get('userId')).run();
  return c.json({ ok: true });
});

api.get('/settings', async (c) => {
  const r = await c.env.DB.prepare('SELECT data FROM user_settings WHERE user_id = ?').bind(c.get('userId')).first<{ data: string }>();
  return c.json(r ? JSON.parse(r.data) : {});
});
api.put('/settings', async (c) => {
  const text = await c.req.text();
  if (text.length > 20_000) return c.json({ error: '大きすぎます' }, 413);
  JSON.parse(text);
  await c.env.DB.prepare('INSERT INTO user_settings (user_id, data, updated_at) VALUES (?, ?, ?) ON CONFLICT(user_id) DO UPDATE SET data = excluded.data, updated_at = excluded.updated_at').bind(c.get('userId'), text, c.get('now')).run();
  return c.json({ ok: true });
});

app.route('/', api);
app.notFound((c) => c.json({ error: 'not found' }, 404));
app.onError((e, c) => {
  console.error(e);
  return c.json({ error: 'サーバーで問題が発生しました' }, 500);
});

/** 毎日 22:00 JST（13:00 UTC）：バックアップ → 成功したユーザーだけ期限処理。5分ごと：通知 */
export async function scheduled(cron: string, env: Env, now: number): Promise<void> {
  applyUserZone(env);
  if (cron === '*/5 * * * *') {
    await runNotifications(env, now);
    return;
  }
  const users = (await env.DB.prepare('SELECT user_id FROM oauth_grants WHERE revoked_at IS NULL').all<{ user_id: string }>()).results;
  for (const { user_id } of users) {
    const b = await runDailyBackup(env, user_id, now);
    if (b.ok) await runRetention(env, user_id, now);
  }
}

export default {
  fetch: (req: Request, env: Env, ctx: ExecutionContext) => app.fetch(req, env, ctx),
  scheduled: async (ev: ScheduledController, env: Env, ctx: ExecutionContext) => {
    ctx.waitUntil(scheduled(ev.cron, env, ev.scheduledTime));
  },
} satisfies ExportedHandler<Env>;
