import { afterEach, expect, it, vi } from 'vitest';
import { reconcilePush } from './pushRegistration';
import { api } from './api';

vi.mock('../data/db', () => ({ db: { name: 'my-time@a' }, ownerOf: (name: string) => name.slice(8) }));
vi.mock('./api', () => ({ api: { subscribePush: vi.fn() } }));
afterEach(() => { vi.unstubAllGlobals(); vi.clearAllMocks(); });
it('ブラウザーに残った許可済み購読をサーバーへ再登録し、別アカウントからは送らない', async () => {
  const payload = { endpoint: 'https://push.example.test/this-device' };
  vi.stubGlobal('Notification', { permission: 'granted' });
  vi.stubGlobal('navigator', { serviceWorker: { getRegistration: async () => ({ pushManager: { getSubscription: async () => ({ toJSON: () => payload }) } }) } });
  await reconcilePush('a');
  expect(api.subscribePush).toHaveBeenCalledTimes(1);
  expect(api.subscribePush).toHaveBeenCalledWith(payload);
  await reconcilePush('b');
  expect(api.subscribePush).toHaveBeenCalledTimes(1);
});
