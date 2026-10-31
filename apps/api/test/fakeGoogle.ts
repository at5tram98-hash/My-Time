import { fetchMock } from 'cloudflare:test';

/**
 * Google（OAuth トークン・JWKS・Drive）の模擬。本物と同じ URL・形式で応答する。
 * 障害の注入（アップロード失敗・読み戻し破損・権限取り消し）もできる。
 */
export interface FakeGoogle {
  files: Map<string, { name: string; parents: string[]; mimeType: string; content: string }>;
  fail: { upload?: boolean; corruptDownload?: boolean; revoked?: boolean; quotaUsage?: number };
  signIdToken: (claims: Record<string, unknown>) => Promise<string>;
  codes: Map<string, { sub: string; email: string; name: string; idToken?: string }>;
  /** ログイン用の認可コードを登録（id_token は事前に署名しておく：模擬応答は同期で返す必要がある） */
  addCode: (code: string, who: { sub: string; email: string; name: string }) => Promise<void>;
  calls: string[];
}

const b64url = (u: Uint8Array | ArrayBuffer) => {
  const a = u instanceof Uint8Array ? u : new Uint8Array(u);
  let s = '';
  for (const b of a) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

let singleton: FakeGoogle | null = null;

/** 模擬はテストファイル内で1回だけ登録し、テストごとに状態を初期化する（古い模擬が残らないように） */
export async function installFakeGoogle(): Promise<FakeGoogle> {
  if (singleton) {
    singleton.files.clear();
    singleton.codes.clear();
    singleton.calls.length = 0;
    for (const k of Object.keys(singleton.fail)) delete (singleton.fail as Record<string, unknown>)[k];
    return singleton;
  }
  fetchMock.activate();
  fetchMock.disableNetConnect();
  const kp = (await crypto.subtle.generateKey({ name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }, true, ['sign', 'verify'])) as CryptoKeyPair;
  const jwk = (await crypto.subtle.exportKey('jwk', kp.publicKey)) as JsonWebKey;
  const fg: FakeGoogle = {
    files: new Map(),
    fail: {},
    codes: new Map(),
    addCode: async () => undefined,
    calls: [],
    signIdToken: async (claims) => {
      const h = b64url(new TextEncoder().encode(JSON.stringify({ alg: 'RS256', kid: 'k1', typ: 'JWT' })));
      const p = b64url(new TextEncoder().encode(JSON.stringify(claims)));
      const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', kp.privateKey, new TextEncoder().encode(`${h}.${p}`));
      return `${h}.${p}.${b64url(sig)}`;
    },
  };

  fg.addCode = async (code, who) => {
    const idToken = await fg.signIdToken({ iss: 'https://accounts.google.com', aud: 'test-client', sub: who.sub, email: who.email, name: who.name, exp: Math.floor(Date.now() / 1000) + 3600 });
    fg.codes.set(code, { ...who, idToken });
  };

  fetchMock
    .get('https://www.googleapis.com')
    .intercept({ path: '/oauth2/v3/certs' })
    .reply(200, { keys: [{ ...jwk, kid: 'k1', alg: 'RS256', use: 'sig' }] })
    .persist();

  fetchMock
    .get('https://oauth2.googleapis.com')
    .intercept({ path: '/token', method: 'POST' })
    .reply((req) => {
      const form = new URLSearchParams(String(req.body));
      fg.calls.push(`token:${form.get('grant_type')}`);
      if (form.get('grant_type') === 'refresh_token') {
        if (fg.fail.revoked) return { statusCode: 400, data: JSON.stringify({ error: 'invalid_grant' }) };
        return { statusCode: 200, data: JSON.stringify({ access_token: 'at-refreshed', expires_in: 3600, scope: 'openid email https://www.googleapis.com/auth/drive.file', token_type: 'Bearer' }) };
      }
      const who = fg.codes.get(form.get('code') ?? '');
      if (!who || !form.get('code_verifier')) return { statusCode: 400, data: JSON.stringify({ error: 'invalid_grant' }) };
      const id_token = who.idToken;
      return { statusCode: 200, data: JSON.stringify({ access_token: 'at-1', expires_in: 3600, refresh_token: `rt-${who.sub}`, scope: 'openid email profile https://www.googleapis.com/auth/drive.file', id_token, token_type: 'Bearer' }) };
    })
    .persist();

  let n = 0;
  const drive = fetchMock.get('https://www.googleapis.com');
  drive
    .intercept({ path: (p) => p.startsWith('/drive/v3/files?') && p.includes('q='), method: 'GET' })
    .reply((req) => {
      const q = new URL(`https://x${req.path}`).searchParams.get('q') ?? '';
      const name = /name='([^']+)'/.exec(q)?.[1];
      const files = [...fg.files.entries()].filter(([, f]) => f.name === name && f.mimeType === 'application/vnd.google-apps.folder').map(([id, f]) => ({ id, name: f.name }));
      return { statusCode: 200, data: JSON.stringify({ files }) };
    })
    .persist();
  drive
    .intercept({ path: (p) => p.startsWith('/drive/v3/files?'), method: 'POST' })
    .reply((req) => {
      const meta = JSON.parse(String(req.body)) as { name: string; mimeType: string };
      const id = `folder-${++n}`;
      fg.files.set(id, { name: meta.name, parents: [], mimeType: meta.mimeType, content: '' });
      return { statusCode: 200, data: JSON.stringify({ id }) };
    })
    .persist();
  drive
    .intercept({ path: (p) => p.startsWith('/upload/drive/v3/files'), method: 'POST' })
    .reply((req) => {
      fg.calls.push('upload');
      if (fg.fail.upload) return { statusCode: 500, data: 'backend error' };
      const body = String(req.body);
      const parts = body.split(/--mt[0-9a-f-]+/).filter((p) => p.includes('content-type'));
      const meta = JSON.parse(parts[0]!.split('\r\n\r\n')[1]!.trim()) as { name: string; parents: string[] };
      const content = parts[1]!.split('\r\n\r\n').slice(1).join('\r\n\r\n').replace(/\r\n$/, '');
      const id = `file-${++n}`;
      fg.files.set(id, { name: meta.name, parents: meta.parents, mimeType: 'application/json', content });
      return { statusCode: 200, data: JSON.stringify({ id, name: meta.name, size: String(content.length) }) };
    })
    .persist();
  drive
    .intercept({ path: (p) => /^\/drive\/v3\/files\/[^/?]+\?alt=media/.test(p), method: 'GET' })
    .reply((req) => {
      const id = decodeURIComponent(/files\/([^?]+)/.exec(req.path)![1]!);
      const f = fg.files.get(id);
      if (!f) return { statusCode: 404, data: 'not found' };
      return { statusCode: 200, data: fg.fail.corruptDownload ? f.content.replace(/"title":"/, '"title":"X') : f.content };
    })
    .persist();
  drive
    .intercept({ path: (p) => /^\/drive\/v3\/files\/[^/?]+$/.test(p), method: 'DELETE' })
    .reply((req) => {
      fg.files.delete(decodeURIComponent(/files\/([^?]+)/.exec(req.path)![1]!));
      return { statusCode: 204, data: '' };
    })
    .persist();
  drive
    .intercept({ path: (p) => p.startsWith('/drive/v3/about'), method: 'GET' })
    .reply(() => ({ statusCode: 200, data: JSON.stringify({ storageQuota: { limit: '1000', usage: String(fg.fail.quotaUsage ?? 100) } }) }))
    .persist();
  singleton = fg;
  return fg;
}
