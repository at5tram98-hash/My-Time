/// <reference lib="webworker" />
import { cleanupOutdatedCaches, createHandlerBoundToURL, precacheAndRoute } from 'workbox-precaching';
import { NavigationRoute, registerRoute } from 'workbox-routing';

declare const self: ServiceWorkerGlobalScope & { __WB_MANIFEST: { url: string; revision: string | null }[] };

// アプリ本体をキャッシュし、オフラインでも起動できるようにする
precacheAndRoute(self.__WB_MANIFEST);
cleanupOutdatedCaches();
// 画面遷移は index.html を返す。ただし API（ログインのリダイレクトなど）は必ずネットワークへ
registerRoute(new NavigationRoute(createHandlerBoundToURL('index.html'), { denylist: [/\/api\//] }));

self.addEventListener('install', () => void self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

interface PushPayload {
  title: string;
  body: string;
  tag?: string;
  target?: { kind: string; id: string | null };
}

self.addEventListener('push', (e) => {
  let p: PushPayload = { title: 'My Time', body: '' };
  try {
    p = e.data?.json() as PushPayload;
  } catch {
    /* 形式が違う場合は既定の文言 */
  }
  e.waitUntil(self.registration.showNotification(p.title, { body: p.body, tag: p.tag, icon: 'icon-192.png', badge: 'icon-192.png', data: p.target ?? null }));
});

self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const t = e.notification.data as PushPayload['target'] | null;
  const url = new URL(self.registration.scope);
  if (t?.kind === 'task' && t.id) url.searchParams.set('task', t.id);
  if (t?.kind === 'event' && t.id) url.searchParams.set('event', t.id);
  e.waitUntil(
    (async () => {
      const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      const w = wins[0];
      if (w) {
        await w.focus();
        w.postMessage({ type: 'open', target: t });
      } else await self.clients.openWindow(url.toString());
    })(),
  );
});
