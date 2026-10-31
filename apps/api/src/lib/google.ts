import type { Env } from '../env';
import { fromB64url } from './crypto';

/** 最小限の権限：ログイン（openid/email/profile）と、このアプリが作ったファイルだけ（drive.file） */
export const GOOGLE_SCOPES = ['openid', 'email', 'profile', 'https://www.googleapis.com/auth/drive.file'];

export interface TokenResponse {
  access_token: string;
  expires_in: number;
  refresh_token?: string;
  scope: string;
  id_token?: string;
  token_type: string;
}

export interface IdClaims {
  sub: string;
  email: string;
  name?: string;
  aud: string;
  iss: string;
  exp: number;
}

export class GoogleError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

export function authUrl(env: Env, state: string, challenge: string): string {
  const u = new URL('/o/oauth2/v2/auth', env.GOOGLE_AUTH_BASE);
  u.searchParams.set('client_id', env.GOOGLE_CLIENT_ID ?? '');
  u.searchParams.set('redirect_uri', `${env.APP_ORIGIN}/api/auth/callback`);
  u.searchParams.set('response_type', 'code');
  u.searchParams.set('scope', GOOGLE_SCOPES.join(' '));
  u.searchParams.set('state', state);
  u.searchParams.set('code_challenge', challenge);
  u.searchParams.set('code_challenge_method', 'S256');
  // 毎日のバックアップをアプリを閉じたまま実行するため、オフラインアクセス（リフレッシュトークン）を求める
  u.searchParams.set('access_type', 'offline');
  u.searchParams.set('prompt', 'consent');
  u.searchParams.set('include_granted_scopes', 'true');
  return u.toString();
}

async function tokenRequest(env: Env, body: Record<string, string>): Promise<TokenResponse> {
  const res = await fetch(env.GOOGLE_TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: env.GOOGLE_CLIENT_ID ?? '', client_secret: env.GOOGLE_CLIENT_SECRET ?? '', ...body }),
  });
  if (!res.ok) throw new GoogleError(`token endpoint ${res.status}: ${(await res.text()).slice(0, 200)}`, res.status);
  return (await res.json()) as TokenResponse;
}

export const exchangeCode = (env: Env, code: string, verifier: string) =>
  tokenRequest(env, { grant_type: 'authorization_code', code, code_verifier: verifier, redirect_uri: `${env.APP_ORIGIN}/api/auth/callback` });

export const refreshAccess = (env: Env, refreshToken: string) => tokenRequest(env, { grant_type: 'refresh_token', refresh_token: refreshToken });

/** id_token（RS256）を Google の公開鍵で検証する。aud・iss・exp も確認 */
export async function verifyIdToken(env: Env, idToken: string, now: number): Promise<IdClaims> {
  const [h, p, s] = idToken.split('.');
  if (!h || !p || !s) throw new GoogleError('id_token の形式が不正です', 401);
  const header = JSON.parse(new TextDecoder().decode(fromB64url(h))) as { kid: string; alg: string };
  if (header.alg !== 'RS256') throw new GoogleError('未対応の署名方式です', 401);
  const jwks = (await (await fetch(env.GOOGLE_JWKS_URL)).json()) as { keys: (JsonWebKey & { kid: string })[] };
  const jwk = jwks.keys.find((k) => k.kid === header.kid);
  if (!jwk) throw new GoogleError('署名鍵が見つかりません', 401);
  const key = await crypto.subtle.importKey('jwk', jwk, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['verify']);
  const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', key, fromB64url(s), new TextEncoder().encode(`${h}.${p}`));
  if (!ok) throw new GoogleError('id_token の署名が不正です', 401);
  const claims = JSON.parse(new TextDecoder().decode(fromB64url(p))) as IdClaims;
  if (claims.aud !== env.GOOGLE_CLIENT_ID) throw new GoogleError('aud が一致しません', 401);
  if (claims.iss !== 'https://accounts.google.com' && claims.iss !== 'accounts.google.com') throw new GoogleError('iss が不正です', 401);
  if (claims.exp * 1000 < now) throw new GoogleError('id_token の期限切れ', 401);
  return claims;
}

// ---------------- Google Drive（drive.file の範囲のみ） ----------------

export interface DriveFile {
  id: string;
  name: string;
  size?: string;
  createdTime?: string;
}

export class Drive {
  constructor(private env: Env, private token: string) {}

  private async call(path: string, init: RequestInit = {}): Promise<Response> {
    const res = await fetch(`${this.env.GOOGLE_API_BASE}${path}`, { ...init, headers: { ...(init.headers ?? {}), authorization: `Bearer ${this.token}` } });
    if (!res.ok) throw new GoogleError(`Drive ${init.method ?? 'GET'} ${path.split('?')[0]} ${res.status}: ${(await res.text()).slice(0, 200)}`, res.status);
    return res;
  }

  async findOrCreateFolder(name: string): Promise<string> {
    const q = encodeURIComponent(`name='${name.replace(/'/g, "\\'")}' and mimeType='application/vnd.google-apps.folder' and trashed=false`);
    const list = (await (await this.call(`/drive/v3/files?q=${q}&fields=files(id,name)&spaces=drive`)).json()) as { files: DriveFile[] };
    if (list.files[0]) return list.files[0].id;
    const created = (await (
      await this.call('/drive/v3/files?fields=id', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name, mimeType: 'application/vnd.google-apps.folder' }) })
    ).json()) as { id: string };
    return created.id;
  }

  async upload(folderId: string, name: string, content: string, appProperties: Record<string, string> = {}): Promise<DriveFile> {
    const boundary = `mt${crypto.randomUUID()}`;
    const meta = JSON.stringify({ name, parents: [folderId], mimeType: 'application/json', appProperties });
    const body = `--${boundary}\r\ncontent-type: application/json; charset=UTF-8\r\n\r\n${meta}\r\n--${boundary}\r\ncontent-type: application/json\r\n\r\n${content}\r\n--${boundary}--`;
    const res = await this.call('/upload/drive/v3/files?uploadType=multipart&fields=id,name,size', { method: 'POST', headers: { 'content-type': `multipart/related; boundary=${boundary}` }, body });
    return (await res.json()) as DriveFile;
  }

  async download(fileId: string): Promise<string> {
    return (await this.call(`/drive/v3/files/${encodeURIComponent(fileId)}?alt=media`)).text();
  }

  async remove(fileId: string): Promise<void> {
    await this.call(`/drive/v3/files/${encodeURIComponent(fileId)}`, { method: 'DELETE' });
  }

  async quota(): Promise<{ limit: number | null; usage: number }> {
    const r = (await (await this.call('/drive/v3/about?fields=storageQuota')).json()) as { storageQuota: { limit?: string; usage: string } };
    return { limit: r.storageQuota.limit ? Number(r.storageQuota.limit) : null, usage: Number(r.storageQuota.usage) };
  }
}
