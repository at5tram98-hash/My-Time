// E2E 用の模擬 Google（OAuth 認可・トークン・JWKS・Drive）。本物と同じ URL 形式で応答する。
// 管理用：POST /__fail {upload,corruptDownload,revoked,quotaUsage} / GET /__files / POST /__reset
import http from 'node:http';
import crypto from 'node:crypto';

const PORT = Number(process.env.PORT ?? 9876);
const CLIENT_ID = process.env.CLIENT_ID ?? 'e2e-client';
const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const jwk = { ...publicKey.export({ format: 'jwk' }), kid: 'e2e', alg: 'RS256', use: 'sig' };
const b64url = (b) => Buffer.from(b).toString('base64url');

let state;
function reset() {
  state = { codes: new Map(), files: new Map(), fail: {}, n: 0, user: { sub: 'e2e-user', email: 'yuki@example.com', name: 'ゆうき' } };
}
reset();

const signIdToken = (claims) => {
  const h = b64url(JSON.stringify({ alg: 'RS256', kid: 'e2e', typ: 'JWT' }));
  const p = b64url(JSON.stringify(claims));
  const s = crypto.sign('RSA-SHA256', Buffer.from(`${h}.${p}`), privateKey).toString('base64url');
  return `${h}.${p}.${s}`;
};

const body = (req) => new Promise((res) => { const c = []; req.on('data', (d) => c.push(d)); req.on('end', () => res(Buffer.concat(c).toString('utf8'))); });
const json = (res, code, obj) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };

http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const p = url.pathname;
  try {
    if (p === '/__reset') { reset(); return json(res, 200, { ok: true }); }
    if (p === '/__fail') { state.fail = JSON.parse(await body(req) || '{}'); return json(res, 200, state.fail); }
    if (p === '/__files') return json(res, 200, [...state.files.entries()].map(([id, f]) => ({ id, name: f.name, mimeType: f.mimeType, size: f.content.length, content: url.searchParams.get('content') ? f.content : undefined })));
    // 同意画面は自動で許可し、redirect_uri に戻す
    if (p === '/o/oauth2/v2/auth') {
      if (url.searchParams.get('client_id') !== CLIENT_ID) return json(res, 400, { error: 'invalid_client' });
      if (url.searchParams.get('code_challenge_method') !== 'S256') return json(res, 400, { error: 'pkce required' });
      const code = crypto.randomUUID();
      state.codes.set(code, { challenge: url.searchParams.get('code_challenge'), redirect: url.searchParams.get('redirect_uri') });
      const back = new URL(url.searchParams.get('redirect_uri'));
      back.searchParams.set('code', code);
      back.searchParams.set('state', url.searchParams.get('state'));
      res.writeHead(302, { location: back.toString() });
      return res.end();
    }
    if (p === '/token' && req.method === 'POST') {
      const f = new URLSearchParams(await body(req));
      if (f.get('grant_type') === 'refresh_token') {
        if (state.fail.revoked) return json(res, 400, { error: 'invalid_grant' });
        return json(res, 200, { access_token: 'at-refreshed', expires_in: 3600, scope: 'openid email profile https://www.googleapis.com/auth/drive.file', token_type: 'Bearer' });
      }
      const c = state.codes.get(f.get('code'));
      state.codes.delete(f.get('code'));
      const verifier = f.get('code_verifier') ?? '';
      if (!c || crypto.createHash('sha256').update(verifier).digest('base64url') !== c.challenge || f.get('redirect_uri') !== c.redirect) return json(res, 400, { error: 'invalid_grant' });
      const now = Math.floor(Date.now() / 1000);
      const id_token = signIdToken({ iss: 'https://accounts.google.com', aud: CLIENT_ID, sub: state.user.sub, email: state.user.email, name: state.user.name, iat: now, exp: now + 3600 });
      return json(res, 200, { access_token: 'at-1', expires_in: 3600, refresh_token: 'rt-e2e', scope: 'openid email profile https://www.googleapis.com/auth/drive.file', id_token, token_type: 'Bearer' });
    }
    if (p === '/oauth2/v3/certs') return json(res, 200, { keys: [jwk] });
    if (p === '/drive/v3/about') return json(res, 200, { storageQuota: { limit: '1000000000', usage: String(state.fail.quotaUsage ?? 1000) } });
    if (p === '/drive/v3/files' && req.method === 'GET') {
      const name = /name='([^']+)'/.exec(url.searchParams.get('q') ?? '')?.[1];
      return json(res, 200, { files: [...state.files.entries()].filter(([, f]) => f.name === name && f.mimeType.includes('folder')).map(([id, f]) => ({ id, name: f.name })) });
    }
    if (p === '/drive/v3/files' && req.method === 'POST') {
      const meta = JSON.parse(await body(req));
      const id = `folder-${++state.n}`;
      state.files.set(id, { name: meta.name, mimeType: meta.mimeType, content: '' });
      return json(res, 200, { id });
    }
    if (p === '/upload/drive/v3/files' && req.method === 'POST') {
      const raw = await body(req);
      if (state.fail.upload) return json(res, 500, { error: 'backend' });
      const parts = raw.split(/--mt[0-9a-f-]+/).filter((x) => x.includes('content-type'));
      const meta = JSON.parse(parts[0].split('\r\n\r\n')[1].trim());
      const content = parts[1].split('\r\n\r\n').slice(1).join('\r\n\r\n').replace(/\r\n$/, '');
      const id = `file-${++state.n}`;
      state.files.set(id, { name: meta.name, mimeType: 'application/json', content });
      return json(res, 200, { id, name: meta.name, size: String(content.length) });
    }
    const m = /^\/drive\/v3\/files\/([^/]+)$/.exec(p);
    if (m) {
      const f = state.files.get(decodeURIComponent(m[1]));
      if (req.method === 'DELETE') { state.files.delete(decodeURIComponent(m[1])); res.writeHead(204); return res.end(); }
      if (!f) return json(res, 404, { error: 'not found' });
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(state.fail.corruptDownload ? f.content.replace('"title":"', '"title":"X') : f.content);
    }
    json(res, 404, { error: `fake: ${req.method} ${p}` });
  } catch (e) {
    json(res, 500, { error: String(e) });
  }
}).listen(PORT, () => console.log(`fake google on ${PORT}`));
