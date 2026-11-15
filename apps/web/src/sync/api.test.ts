import { afterEach, expect, it, vi } from 'vitest';

vi.mock('../data/db', () => ({
  db: { name: 'my-time@account-a' },
  ownerOf: (name: string) => name.startsWith('my-time@') ? name.slice(8) : null,
}));
import { api, REQUEST_TIMEOUT_MS } from './api';

afterEach(() => { vi.restoreAllMocks(); localStorage.clear(); });

it('別タブがアカウントを切り替えても、操作の宛先は現在の画面のDBの持ち主に固定する', async () => {
  localStorage.setItem('mytime:activeDb', 'my-time@account-b');
  const fetch = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({ items: [] }), { headers: { 'content-type': 'application/json' } }));
  await api.backups();
  const request = fetch.mock.calls[0]![1]!;
  expect(new Headers(request.headers).get('x-mytime-account')).toBe('account-a');
  // The server then rejects this A request if its session cookie has switched to B.
});

it('応答が止まった通信は上限時間で切り、オフライン扱いにする（同期が「同期中」のまま止まらない）', async () => {
  vi.useFakeTimers();
  try {
    vi.spyOn(globalThis, 'fetch').mockImplementation((_url, init) => new Promise((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
    }));
    const p = api.backups();
    const check = expect(p).rejects.toMatchObject({ status: 0 });
    await vi.advanceTimersByTimeAsync(REQUEST_TIMEOUT_MS + 1);
    await check;
  } finally {
    vi.useRealTimers();
  }
});
