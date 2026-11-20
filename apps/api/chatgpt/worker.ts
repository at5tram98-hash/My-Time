import { pkceChallenge, randomToken, sha256b64url } from '../src/lib/crypto';

type Env = { DB: D1Database; ORIGIN: string };
type Dict = Record<string, unknown>;
type OAuthRow = { challenge: string | null; refresh_group: string | null };
const CLIENT = 'https://chatgpt.com/oauth/client.json';
const CALLBACK = 'https://chatgpt.com/connector_platform_oauth_redirect';
const CODEX_CLIENT = 'https://chatgpt.com/oauth/codex/client.json';

function validCallback(client: unknown, redirect: unknown): redirect is string {
  if (client === CLIENT) return redirect === CALLBACK;
  if (client !== CODEX_CLIENT || typeof redirect !== 'string') return false;
  const loopback = /^http:\/\/(127\.0\.0\.1|localhost):([1-9][0-9]{0,4})\/callback$/.exec(redirect);
  return Boolean(loopback && Number(loopback[2]) <= 65535);
}
const SCOPE = 'mytime:connect';
const MIN = 60_000;
const DAY = 24 * 60 * MIN;
const TOKEN = /^[A-Za-z0-9_-]{43}$/;
const ID = /^[A-Za-z0-9_:@.-]{1,500}$/;
const LIMIT = 1_500_000;

const headers = { 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer' };
const send = (data: unknown, status = 200, extra?: Record<string, string>) => Response.json(data, { status, headers: { ...headers, ...extra } });
const error = (message: string, status: number) => send({ error: message }, status);
const obj = (x: unknown): Dict => x && typeof x === 'object' && !Array.isArray(x) ? x as Dict : {};
const list = (x: unknown): unknown[] => Array.isArray(x) ? x : [];
const value = (x: unknown) => typeof x === 'string' ? x : '';
const stamp = (x: unknown): x is number => typeof x === 'number' && Number.isSafeInteger(x) && Math.abs(x) < 8e12;
const bearer = (req: Request) => req.headers.get('authorization')?.match(/^Bearer ([A-Za-z0-9_-]{43})$/i)?.[1];

async function body(req: Request): Promise<Dict> {
  if (!req.body) return {};
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value: part } = await reader.read();
    if (done) break;
    size += part.byteLength;
    if (size > LIMIT) { await reader.cancel(); throw new RangeError(); }
    chunks.push(part);
  }
  const text = await new Blob(chunks).text();
  return req.headers.get('content-type')?.startsWith('application/x-www-form-urlencoded')
    ? Object.fromEntries(new URLSearchParams(text)) : obj(JSON.parse(text));
}

function html(content: string, callbackOrigin: string) {
  return new Response('<!doctype html><html lang="ja"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>My Time</title><main><h1>My TimeをChatGPTに接続</h1>' + content + '</main></html>', {
    headers: { ...headers, 'Referrer-Policy': 'same-origin', 'Content-Type': 'text/html; charset=utf-8', 'Content-Security-Policy': `default-src 'none'; form-action 'self' ${callbackOrigin}; base-uri 'none'; frame-ancestors 'none'` },
  });
}

function escape(s: string) {
  return s.replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]!));
}

async function deviceAuth(req: Request, db: D1Database) {
  const token = bearer(req);
  if (!token) return false;
  return Boolean(await db.prepare('SELECT id FROM device WHERE id=1 AND hash=?').bind(await sha256b64url(token)).first());
}

async function authorize(req: Request, env: Env, url: URL, now: number): Promise<Response> {
  const q = Object.fromEntries(url.searchParams);
  const resource = env.ORIGIN + '/mcp';
  if (!validCallback(q.client_id, q.redirect_uri) || q.response_type !== 'code' ||
      q.resource !== resource || q.code_challenge_method !== 'S256' || !TOKEN.test(q.code_challenge ?? '') ||
      !q.state || q.state.length > 1000 || (q.scope && q.scope !== SCOPE)) return error('invalid_request', 400);
  if (req.method === 'GET') return html('<p>最新の同期データを読み取り、変更依頼をiPhoneに送ります。My Timeの連携画面で作った接続コードを入力してください。</p><form method="post" action="' + escape(url.pathname + url.search) + '"><label>接続コード <input name="pair" required autocomplete="off" autocapitalize="off" spellcheck="false"></label> <button>接続を許可</button></form>', new URL(q.redirect_uri).origin);
  if (req.headers.get('origin') !== env.ORIGIN) return error('invalid_origin', 403);
  const pair = value((await body(req)).pair).trim();
  if (!TOKEN.test(pair)) return error('接続コードが無効です', 400);
  const pairHash = await sha256b64url(pair);
  const code = randomToken();
  const inserted = await env.DB.batch([
    env.DB.prepare("INSERT INTO oauth(hash,kind,expires,challenge) SELECT ?,'code',?,? WHERE EXISTS (SELECT 1 FROM oauth WHERE hash=? AND kind='pair' AND expires>?)").bind(await sha256b64url(code), now + 2 * MIN, JSON.stringify([q.client_id, q.redirect_uri, q.code_challenge]), pairHash, now),
    env.DB.prepare("DELETE FROM oauth WHERE hash=? AND kind='pair'").bind(pairHash),
  ]);
  if (!inserted[0]?.meta.changes) return error('コードの期限が切れたか、すでに使用されています', 403);
  const redirect = new URL(q.redirect_uri);
  redirect.searchParams.set('code', code);
  redirect.searchParams.set('state', q.state);
  redirect.searchParams.set('iss', env.ORIGIN);
  return new Response(null, { status: 303, headers: { ...headers, Location: redirect.href } });
}

async function issueToken(req: Request, env: Env, now: number) {
  const q = await body(req);
  const grant = q.grant_type;
  const resource = env.ORIGIN + '/mcp';
  if ((q.client_id !== CLIENT && q.client_id !== CODEX_CLIENT) || (q.resource !== resource && !(grant === 'refresh_token' && q.resource === undefined))) {
    return error('invalid_client', 400);
  }
  let oldHash: string;
  let challenge = '';
  if (grant === 'authorization_code') {
    if (!validCallback(q.client_id, q.redirect_uri) || !TOKEN.test(value(q.code)) || !/^[A-Za-z0-9._~-]{43,128}$/.test(value(q.code_verifier))) return error('invalid_grant', 400);
    oldHash = await sha256b64url(value(q.code));
    challenge = await pkceChallenge(value(q.code_verifier));
  } else if (grant === 'refresh_token' && TOKEN.test(value(q.refresh_token))) {
    oldHash = await sha256b64url(value(q.refresh_token));
  } else {
    return error('unsupported_grant_type', 400);
  }
  const db = env.DB;
  const kind = grant === 'authorization_code' ? 'code' : 'refresh';
  const previous = await db.prepare('SELECT challenge,refresh_group FROM oauth WHERE hash=? AND kind=? AND expires>?')
    .bind(oldHash, kind, now).first<OAuthRow>();
  const binding = kind === 'code' ? JSON.stringify([q.client_id, q.redirect_uri, challenge]) : q.client_id;
  const legacyBinding = kind === 'code' ? challenge : null;
  if (!previous || (previous.challenge !== binding && !(q.client_id === CLIENT && previous.challenge === legacyBinding))) {
    return error('invalid_grant', 400);
  }
  const access = randomToken(), refresh = randomToken(), group = previous.refresh_group ?? randomToken();
  const accessHash = await sha256b64url(access), refreshHash = await sha256b64url(refresh);
  const commands = [
    db.prepare("INSERT INTO oauth(hash,kind,expires,refresh_group) SELECT ?,'access',?,? WHERE EXISTS (SELECT 1 FROM oauth WHERE hash=? AND kind=? AND expires>?)").bind(accessHash, now + 60 * MIN, group, oldHash, kind, now),
    db.prepare("INSERT INTO oauth(hash,kind,expires,refresh_group,challenge) SELECT ?,'refresh',?,?,? WHERE EXISTS (SELECT 1 FROM oauth WHERE hash=? AND kind=? AND expires>?)").bind(refreshHash, now + 90 * DAY, group, q.client_id, oldHash, kind, now),
    db.prepare('DELETE FROM oauth WHERE hash=? OR expires<=?').bind(oldHash, now),
  ];
  const result = await db.batch(commands);
  if (!result[0]?.meta.changes) return error('invalid_grant', 400);
  return send({ access_token: access, token_type: 'Bearer', expires_in: 3600, refresh_token: refresh, scope: SCOPE });
}

async function native(req: Request, env: Env, path: string, now: number) {
  const db = env.DB;
  if (path === '/device/connect' && req.method === 'POST') {
    const bodyData = await body(req);
    const setup = value(bodyData.code).trim();
    if (!TOKEN.test(setup)) return error('セットアップコードが無効です', 400);
    const key = value(bodyData.deviceToken);
    if (!TOKEN.test(key)) return error('iPhoneの接続情報が不正です', 400);
    const keyHash = await sha256b64url(key), setupHash = await sha256b64url(setup);
    const result = await db.batch([
      db.prepare('INSERT OR IGNORE INTO device(id,hash) SELECT 1,? WHERE EXISTS (SELECT 1 FROM enrollment WHERE hash=? AND expires>?)')
        .bind(keyHash, setupHash, now),
      db.prepare('DELETE FROM enrollment WHERE hash=? AND EXISTS(SELECT 1 FROM device WHERE id=1 AND hash=?)').bind(setupHash, keyHash),
      db.prepare('SELECT id FROM device WHERE id=1 AND hash=?').bind(keyHash),
    ]);
    return result[2]?.results.length ? send({ ok: true }) : error('コードの期限が切れたか、接続済みです', 403);
  }
  if (!await deviceAuth(req, db)) return error('iPhoneの接続が必要です', 401);
  if (path === '/device/pair' && req.method === 'POST') {
    const code = randomToken();
    await db.batch([
      db.prepare("DELETE FROM oauth WHERE kind='pair' OR expires<=?").bind(now),
      db.prepare("INSERT INTO oauth(hash,kind,expires) VALUES (?,'pair',?)").bind(await sha256b64url(code), now + 10 * MIN),
    ]);
    return send({ code });
  }
  if (path === '/device/sync' && req.method === 'POST') {
    const b = await body(req);
    if (b.snapshot !== undefined) {
      const snapshot = obj(b.snapshot);
      if (snapshot.format !== 'my-time-snapshot-v1' || !stamp(snapshot.from) || !stamp(snapshot.to) || snapshot.to <= snapshot.from ||
          !Array.isArray(snapshot.occurrences) || !Array.isArray(snapshot.task) || !Array.isArray(snapshot.checkpoint)) return error('同期データの形式が不正です', 400);
      const text = JSON.stringify(snapshot);
      if (new TextEncoder().encode(text).byteLength > 700_000) return error('同期データが上限を超えています', 413);
      await db.prepare('UPDATE device SET synced=?, snapshot=? WHERE id=1 AND hash=?').bind(now, text, await sha256b64url(bearer(req)!)).run();
    }
    const pending = await db.prepare("SELECT id,created,payload FROM proposals WHERE status='pending' AND created>? ORDER BY created LIMIT 50").bind(now - 7 * DAY).all<{id: string; created: number; payload: string}>();
    return send({ pending: pending.results.map(p => ({ id: p.id, created: p.created, payload: JSON.parse(p.payload) })) });
  }
  if (path === '/device/result' && req.method === 'POST') {
    const b = await body(req), id = value(b.id), status = value(b.status);
    if (!ID.test(id) || !['applied', 'rejected'].includes(status)) return error('invalid_result', 400);
    await db.prepare("UPDATE proposals SET status=?,payload='{}' WHERE id=? AND status='pending'").bind(status, id).run();
    return send({ ok: true });
  }
  if (path === '/device/revoke-chatgpt' && req.method === 'POST') {
    await db.batch([db.prepare('DELETE FROM oauth'), db.prepare("UPDATE proposals SET status='rejected',payload='{}' WHERE status='pending'")]);
    return send({ ok: true });
  }
  if (path === '/device/disconnect' && req.method === 'POST') {
    await db.batch([db.prepare('DELETE FROM oauth'), db.prepare('DELETE FROM proposals'), db.prepare('DELETE FROM device')]);
    return send({ ok: true });
  }
  return error('not_found', 404);
}

const string = { type: 'string' };
const epoch = { type: 'integer', description: 'UNIX milliseconds' };
const permissions = [{ type: 'oauth2', scopes: [SCOPE] }];
const schema = (properties: Dict, required: string[]) => ({ type: 'object', properties, required, additionalProperties: false });
const tools = [
  { name: 'mytime_list', description: 'Read the latest My Time iPhone sync. Report lastSyncedAt and warn if stale or outside coverage. Events include occurrences and their master record ID and revision.', inputSchema: schema({ from: epoch, to: epoch, kind: { enum: ['event', 'task', 'checkpoint'] }, offset: { type: 'integer', minimum: 0 }, limit: { type: 'integer', minimum: 1, maximum: 50 } }, ['from', 'to', 'kind']), annotations: { readOnlyHint: true, openWorldHint: false } },
  { name: 'mytime_propose_changes', description: 'Queue a change for review in the My Time iPhone app. State it is pending until the iPhone approves. For edits/deletes use exact ID and revision from mytime_list; explicitly confirm recurring series. For TimeTree, preserve original events in a my-time-timetree-v1 payload.', inputSchema: schema({ requestId: { type: 'string', description: 'A new UUID for this request. Reuse on retry.' }, payload: { type: 'object', description: 'my-time-changes-v1 with changes array (action add/edit/delete, kind event/task/checkpoint, id, revision for edit/delete, fields for add/edit); or my-time-timetree-v1 with events array.' } }, ['requestId', 'payload']), annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false } },
  { name: 'mytime_change_status', description: 'Check whether an iPhone approved or rejected a queued My Time change.', inputSchema: schema({ requestId: string }, ['requestId']), annotations: { readOnlyHint: true, openWorldHint: false } },
].map(tool => ({ ...tool, securitySchemes: permissions, _meta: { securitySchemes: permissions } }));

async function callTool(name: unknown, args: Dict, db: D1Database, now: number, accessHash: string): Promise<Dict> {
  if (name === 'mytime_propose_changes') {
    const id = value(args.requestId), payload = obj(args.payload), text = JSON.stringify(payload);
    const entries = payload.format === 'my-time-changes-v1' ? list(payload.changes) : payload.format === 'my-time-timetree-v1' ? list(payload.events) : [];
    if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(id) ||
        !entries.length || entries.length > 50 || new TextEncoder().encode(text).byteLength > 120_000) throw new Error('変更は1〜50件、リクエストIDはUUIDを指定してください');
    await db.prepare("DELETE FROM proposals WHERE created<=?").bind(now - 7 * DAY).run();
    await db.prepare("INSERT OR IGNORE INTO proposals(id,created,status,payload) SELECT ?,?,'pending',? WHERE (SELECT COUNT(*) FROM proposals WHERE status='pending')<50 AND EXISTS (SELECT 1 FROM oauth WHERE hash=? AND kind='access' AND expires>?)")
      .bind(id, now, text, accessHash, now).run();
    const p = await db.prepare('SELECT status,payload FROM proposals WHERE id=?').bind(id).first<{status: string; payload: string}>();
    if (!p) throw new Error('確認待ちが上限の50件に達しています');
    if (p.status === 'pending' && p.payload !== text) throw new Error('同じリクエストIDが別の変更に使われています');
    return { requestId: id, status: p.status };
  }
  if (name === 'mytime_change_status') {
    const id = value(args.requestId);
    const p = await db.prepare('SELECT status FROM proposals WHERE id=? AND created>?').bind(id, now - 7 * DAY).first<{status: string}>();
    return { requestId: id, status: p?.status ?? 'not_found' };
  }
  if (name !== 'mytime_list') throw new Error('Unknown tool');
  const { from, to, kind } = args;
  if (!stamp(from) || !stamp(to) || from >= to || !['event', 'task', 'checkpoint'].includes(value(kind))) throw new Error('期間と種類を指定してください');
  const row = await db.prepare('SELECT synced,snapshot FROM device WHERE id=1').first<{synced: number; snapshot: string}>();
  if (!row?.snapshot) return { status: 'not_synced', lastSyncedAt: null, items: [] };
  const s = obj(JSON.parse(row.snapshot));
  const offset = Number.isSafeInteger(args.offset) ? Math.max(0, Number(args.offset)) : 0;
  const limit = Number.isSafeInteger(args.limit) ? Math.max(1, Math.min(50, Number(args.limit))) : 25;
  const data = list(kind === 'event' ? s.occurrences : s[value(kind)]).map(obj).filter(x => {
    const start = (x.start ?? x.plannedStart ?? x.checkAt ?? x.onDay ?? x.at) as number | undefined;
    const end = (x.end ?? x.plannedEnd) as number | undefined;
    return start == null || (start < to && ((end ?? start + 1) > from || (kind === 'checkpoint' && Boolean(x.repeat))));
  });
  const covered = from >= Number(s.from) && to <= Number(s.to);
  return { status: 'synced', covered, coverage: { from: s.from, to: s.to }, lastSyncedAt: new Date(row.synced).toISOString(),
    stale: now - row.synced > 5 * MIN, timeZone: s.timeZone, calendars: s.calendars,
    items: data.slice(offset, offset + limit).map(x => ({ ...x, ...(typeof x.notes === 'string' && x.notes.length > 400 ? { notes: x.notes.slice(0, 400), notesTruncated: true } : {}) })),
    nextOffset: offset + limit < data.length ? offset + limit : null };
}

async function mcp(req: Request, env: Env, now: number) {
  if (req.method !== 'POST') return send({ error: 'method_not_allowed' }, 405, { Allow: 'POST' });
  const b = await body(req);
  const reply = (result: unknown) => send({ jsonrpc: '2.0', id: b.id, result });
  if (b.jsonrpc !== '2.0') return error('invalid_request', 400);
  if (b.method === 'initialize') {
    const version = obj(b.params).protocolVersion;
    return reply({ protocolVersion: ['2025-03-26', '2025-06-18', '2025-11-25'].includes(value(version)) ? version : '2025-06-18',
      capabilities: { tools: {} }, serverInfo: { name: 'My Time', version: '1.0.0' } });
  }
  if (b.id == null) return new Response(null, { status: 202, headers });
  if (b.method === 'ping') return reply({});
  if (b.method === 'tools/list') return reply({ tools });
  if (b.method !== 'tools/call') return send({ jsonrpc: '2.0', id: b.id, error: { code: -32601, message: 'Method not found' } });
  const token = bearer(req);
  const accessHash = token ? await sha256b64url(token) : "";
  if (!accessHash || !await env.DB.prepare("SELECT hash FROM oauth WHERE hash=? AND kind='access' AND expires>?").bind(accessHash, now).first()) {
    const challenge = `Bearer resource_metadata="${env.ORIGIN}/.well-known/oauth-protected-resource/mcp", scope="${SCOPE}"`;
    return send({ error: 'unauthorized' }, 401, { 'WWW-Authenticate': challenge });
  }
  try {
    const p = obj(b.params);
    const data = await callTool(p.name, obj(p.arguments), env.DB, now, accessHash);
    return reply({ structuredContent: data, content: [{ type: 'text', text: JSON.stringify(data) }] });
  } catch (e) {
    return reply({ isError: true, content: [{ type: 'text', text: e instanceof Error && !/D1|SQL/i.test(e.message) ? e.message : 'My Timeの処理に失敗しました' }] });
  }
}

export default {
  async fetch(req: Request, env: Env) {
    const url = new URL(req.url), path = url.pathname, now = Date.now();
    try {
      if (path === '/health' && req.method === 'GET') return send({ service: 'my-time-chatgpt', version: 1 });
      if (path === '/.well-known/oauth-protected-resource/mcp' && req.method === 'GET') return send({ resource: env.ORIGIN + '/mcp', authorization_servers: [env.ORIGIN], scopes_supported: [SCOPE], bearer_methods_supported: ['header'] });
      if (path === '/.well-known/oauth-authorization-server' && req.method === 'GET') return send({
        issuer: env.ORIGIN, authorization_endpoint: env.ORIGIN + '/authorize', token_endpoint: env.ORIGIN + '/token',
        response_types_supported: ['code'], grant_types_supported: ['authorization_code', 'refresh_token'],
        token_endpoint_auth_methods_supported: ['none'], code_challenge_methods_supported: ['S256'], scopes_supported: [SCOPE],
        client_id_metadata_document_supported: true, authorization_response_iss_parameter_supported: true,
      });
      if (path === '/authorize' && ['GET', 'POST'].includes(req.method)) return await authorize(req, env, url, now);
      if (path === '/token' && req.method === 'POST') return await issueToken(req, env, now);
      if (path.startsWith('/device/')) return await native(req, env, path, now);
      if (path === '/mcp') return await mcp(req, env, now);
      return error('not_found', 404);
    } catch (e) {
      if (e instanceof RangeError) return error('payload_too_large', 413);
      if (e instanceof SyntaxError) return error('invalid_request', 400);
      return error('server_error', 500);
    }
  },
} satisfies ExportedHandler<Env>;
