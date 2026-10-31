import { Hono, type MiddlewareHandler } from 'hono';
import { deleteCookie, getCookie, setCookie } from 'hono/cookie';
import { googleConfigured, type AppBindings, type Env } from '../env';
import { encryptSecret, newId, pkceChallenge, randomToken, sha256b64url } from '../lib/crypto';
import { authUrl, exchangeCode, verifyIdToken } from '../lib/google';
import { resolveNotice } from '../lib/store';

export const SESSION_COOKIE = 'mt_session';
const SESSION_DAYS = 90;
const STATE_TTL = 10 * 60_000;

function cookieSecure(env: Env) {
  return env.APP_ORIGIN.startsWith('https://');
}

export const authRoutes = new Hono<AppBindings>();

/** Google ログイン開始（認可コード + PKCE + state） */
authRoutes.get('/login', async (c) => {
  if (!googleConfigured(c.env)) return c.json({ error: 'Google ログインはまだ設定されていません' }, 503);
  const now = c.get('now');
  const state = randomToken();
  const verifier = randomToken(48);
  await c.env.DB.batch([
    c.env.DB.prepare('DELETE FROM oauth_states WHERE created_at < ?').bind(now - STATE_TTL),
    c.env.DB.prepare('INSERT INTO oauth_states (state, code_verifier, created_at) VALUES (?, ?, ?)').bind(state, verifier, now),
  ]);
  return c.redirect(authUrl(c.env, state, await pkceChallenge(verifier)), 302);
});

/** Google からの戻り先。state を1回限りで照合し、id_token を検証してからセッションを作る */
authRoutes.get('/callback', async (c) => {
  const now = c.get('now');
  const fail = (reason: string) => c.redirect(`/?login=error&reason=${encodeURIComponent(reason)}`, 302);
  const err = c.req.query('error');
  if (err) return fail(err === 'access_denied' ? '許可されませんでした' : err);
  const state = c.req.query('state');
  const code = c.req.query('code');
  if (!state || !code) return fail('パラメータが不足しています');
  const row = await c.env.DB.prepare('DELETE FROM oauth_states WHERE state = ? RETURNING code_verifier, created_at').bind(state).first<{ code_verifier: string; created_at: number }>();
  if (!row || now - row.created_at > STATE_TTL) return fail('ログインの有効期限が切れました。もう一度お試しください');
  try {
    const tok = await exchangeCode(c.env, code, row.code_verifier);
    if (!tok.id_token) return fail('id_token がありません');
    const claims = await verifyIdToken(c.env, tok.id_token, now);
    const existing = await c.env.DB.prepare('SELECT id FROM users WHERE google_sub = ?').bind(claims.sub).first<{ id: string }>();
    const userId = existing?.id ?? newId();
    const stmts = [
      existing
        ? c.env.DB.prepare('UPDATE users SET email = ?, name = ?, updated_at = ? WHERE id = ?').bind(claims.email, claims.name ?? '', now, userId)
        : c.env.DB.prepare('INSERT INTO users (id, google_sub, email, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)').bind(userId, claims.sub, claims.email, claims.name ?? '', now, now),
    ];
    if (tok.refresh_token) {
      const encd = await encryptSecret(tok.refresh_token, c.env.TOKEN_ENC_KEY!);
      stmts.push(
        c.env.DB.prepare(
          `INSERT INTO oauth_grants (user_id, refresh_token_enc, scope, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(user_id) DO UPDATE SET refresh_token_enc = excluded.refresh_token_enc, scope = excluded.scope, updated_at = excluded.updated_at, revoked_at = NULL`,
        ).bind(userId, encd, tok.scope, now, now),
      );
    }
    const token = randomToken();
    stmts.push(c.env.DB.prepare('INSERT INTO sessions (id, user_id, created_at, expires_at, user_agent) VALUES (?, ?, ?, ?, ?)').bind(await sha256b64url(token), userId, now, now + SESSION_DAYS * 86_400_000, (c.req.header('user-agent') ?? '').slice(0, 200)));
    await c.env.DB.batch(stmts);
    if (tok.refresh_token) await resolveNotice(c.env.DB, userId, 'auth:drive-revoked', now);
    setCookie(c, SESSION_COOKIE, token, { httpOnly: true, secure: cookieSecure(c.env), sameSite: 'Lax', path: '/', maxAge: SESSION_DAYS * 86_400 });
    return c.redirect('/?login=ok', 302);
  } catch (e) {
    console.error('oauth callback', e);
    return fail('Google との通信に失敗しました');
  }
});

authRoutes.post('/logout', async (c) => {
  const token = getCookie(c, SESSION_COOKIE);
  if (token) await c.env.DB.prepare('DELETE FROM sessions WHERE id = ?').bind(await sha256b64url(token)).run();
  deleteCookie(c, SESSION_COOKIE, { path: '/' });
  return c.json({ ok: true });
});

/** セッション確認。状態を変える API は独自ヘッダー必須（他サイトからのフォーム送信を防ぐ） */
export const requireUser: MiddlewareHandler<AppBindings> = async (c, next) => {
  if (c.req.method !== 'GET' && c.req.header('x-mytime') !== '1') return c.json({ error: 'forbidden' }, 403);
  const token = getCookie(c, SESSION_COOKIE);
  if (!token) return c.json({ error: 'ログインが必要です' }, 401);
  const s = await c.env.DB.prepare('SELECT user_id, expires_at FROM sessions WHERE id = ?').bind(await sha256b64url(token)).first<{ user_id: string; expires_at: number }>();
  if (!s || s.expires_at < c.get('now')) return c.json({ error: 'ログインが必要です' }, 401);
  c.set('userId', s.user_id);
  await next();
};
