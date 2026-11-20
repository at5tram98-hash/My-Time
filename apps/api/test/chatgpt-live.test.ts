import { env } from 'cloudflare:test';
import { expect, it } from 'vitest';
import liveWorker from '../chatgpt/worker';
import schema from '../chatgpt/schema.sql?raw';
import { pkceChallenge, randomToken, sha256b64url } from '../src/lib/crypto';

const web = { client: 'https://chatgpt.com/oauth/client.json', callback: 'https://chatgpt.com/connector_platform_oauth_redirect' };
const codex = { client: 'https://chatgpt.com/oauth/codex/client.json', callback: 'http://127.0.0.1:49217/callback' };

it.each([web, codex])('pairs $client, protects schedules, and tracks changes until iPhone approval', async ({ client, callback }) => {
  const origin = 'https://mytime.test';
  const resource = origin + '/mcp';
  const DB = env.RECOVERY_DB;
  for (const sql of schema.split(';').filter(s => s.trim())) await DB.prepare(sql).run();
  const setup = randomToken();
  await DB.prepare('INSERT INTO enrollment VALUES (?,?)').bind(await sha256b64url(setup), Date.now() + 60_000).run();
  const get = (path: string) => liveWorker.fetch(new Request(origin + path), { DB, ORIGIN: origin });
  const post = (path: string, body: object | URLSearchParams, token?: string) => {
    const form = body instanceof URLSearchParams;
    return liveWorker.fetch(new Request(origin + path, {
      method: 'POST', body: form ? body : JSON.stringify(body),
      headers: { 'Content-Type': form ? 'application/x-www-form-urlencoded' : 'application/json', Origin: origin,
        ...(token ? { Authorization: 'Bearer ' + token } : {}) },
    }), { DB, ORIGIN: origin });
  };
  const rpc = (name: string, args: object, token?: string) => post('/mcp', {
    jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args },
  }, token);
  const from = Date.now(), to = from + 60_000;
  const filter = { from, to, kind: 'event' };
  expect((await rpc('mytime_list', filter)).status).toBe(401);
  const device = { token: randomToken() };
  expect((await post('/device/connect', { code: setup, deviceToken: device.token })).status).toBe(200);
  expect((await post('/device/connect', { code: setup, deviceToken: device.token })).status).toBe(200);
  expect((await post('/device/connect', { code: setup, deviceToken: randomToken() })).status).toBe(403);
  expect((await rpc('mytime_list', filter, device.token)).status).toBe(401);
  const pair = await (await post('/device/pair', {}, device.token)).json<{ code: string }>();
  const verifier = randomToken();
  const params = new URLSearchParams({ client_id: client, redirect_uri: callback,
    response_type: 'code', scope: 'mytime:connect', resource, state: 'test-state',
    code_challenge: await pkceChallenge(verifier), code_challenge_method: 'S256' });
  const formPage = await get('/authorize?' + params);
  expect(formPage.status).toBe(200);
  expect(formPage.headers.get('Content-Security-Policy')).toContain("form-action 'self' " + new URL(callback).origin);
  for (const badRedirect of ['https://other.example/callback', 'http://127.0.0.1:49217/wrong']) {
    const invalid = new URLSearchParams(params);
    invalid.set('redirect_uri', badRedirect);
    expect((await get('/authorize?' + invalid)).status).toBe(400);
  }
  const auth = await post('/authorize?' + params, new URLSearchParams({ pair: pair.code }));
  expect(auth.status).toBe(303);
  const location = new URL(auth.headers.get('Location')!);
  expect(location.searchParams.get('iss')).toBe(origin);
  expect(location.searchParams.get('state')).toBe('test-state');
  expect((await post('/authorize?' + params, new URLSearchParams({ pair: pair.code }))).status).toBe(403);
  const tokenForm = new URLSearchParams({ grant_type: 'authorization_code', client_id: client,
    redirect_uri: callback, resource, code: location.searchParams.get('code')!, code_verifier: verifier });
  const another = client === web.client ? codex : web;
  const swapped = new URLSearchParams(tokenForm);
  swapped.set('client_id', another.client);
  swapped.set('redirect_uri', another.callback);
  expect((await post('/token', swapped)).status).toBe(400);
  if (client === codex.client) {
    const changedPort = new URLSearchParams(tokenForm);
    changedPort.set('redirect_uri', 'http://127.0.0.1:49218/callback');
    expect((await post('/token', changedPort)).status).toBe(400);
  }
  const incorrect = new URLSearchParams(tokenForm);
  incorrect.set('code_verifier', randomToken());
  expect((await post('/token', incorrect)).status).toBe(400);
  const access = await (await post('/token', tokenForm)).json<{ access_token: string; refresh_token: string }>();
  expect((await post('/token', tokenForm)).status).toBe(400);
  const token = access.access_token;
  const synced = await post('/device/sync', { snapshot: { format: 'my-time-snapshot-v1',
    from, to, task: [], checkpoint: [], occurrences: [{ title: '試験予定', id: 'test', start: from + 1, end: to }] } }, device.token);
  expect(synced.status).toBe(200);
  const listed = await (await rpc('mytime_list', filter, token)).json<{ result: { structuredContent: Record<string, unknown> } }>();
  expect(listed.result.structuredContent).toMatchObject({ covered: true, stale: false, items: [{ id: 'test', title: '試験予定' }] });

  const id = crypto.randomUUID();
  const args = { requestId: id, payload: { format: 'my-time-changes-v1', changes: [
    { action: 'add', kind: 'task', id: crypto.randomUUID(), fields: { title: '確認' } },
  ] } };
  const getStatus = async () => {
    const res = await rpc('mytime_change_status', { requestId: id }, token);
    return (await res.json<{ result: { structuredContent: { status: string } } }>()).result.structuredContent.status;
  };
  await rpc('mytime_propose_changes', args, token);
  await rpc('mytime_propose_changes', args, token);
  expect(await getStatus()).toBe('pending');
  const inbox = await (await post('/device/sync', {}, device.token)).json<{ pending: unknown[] }>();
  expect(inbox.pending).toHaveLength(1);
  expect((await post('/device/result', { id, status: 'applied' }, token)).status).toBe(401);
  expect((await post('/device/result', { id, status: 'applied' }, device.token)).status).toBe(200);
  expect(await getStatus()).toBe('applied');
  const refresh = new URLSearchParams({ grant_type: 'refresh_token', client_id: client, resource,
    refresh_token: access.refresh_token });
  const wrongClient = new URLSearchParams(refresh);
  wrongClient.set('client_id', another.client);
  expect((await post('/token', wrongClient)).status).toBe(400);
  expect((await post('/token', refresh)).status).toBe(200);
  expect((await post('/token', refresh)).status).toBe(400);
  expect((await post('/device/disconnect', {}, device.token)).status).toBe(200);
  expect((await rpc('mytime_list', filter, token)).status).toBe(401);
});
