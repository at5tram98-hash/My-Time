import { expandAll, planNotices, type CalEvent, type Employer, type Task } from '@my-time/domain';
import { pushConfigured, applyUserZone, type Env } from '../env';
import { liveRecords } from '../lib/store';
import { sendPush } from '../lib/webpush';

const WINDOW = 6 * 60_000; // 5分ごとの Cron + 余裕

/** 5分ごと：送るべき通知を計算し、未送信のものだけ Push する（同じ通知は二度送らない） */
export async function runNotifications(env: Env, now: number): Promise<{ sent: number }> {
  if (!pushConfigured(env)) return { sent: 0 };
  applyUserZone(env);
  const users = (await env.DB.prepare('SELECT DISTINCT user_id FROM push_subscriptions').all<{ user_id: string }>()).results;
  let sent = 0;
  for (const { user_id: userId } of users) {
    const [tasks, events, employers] = await Promise.all([
      liveRecords<Task>(env.DB, userId, 'task'),
      liveRecords<CalEvent>(env.DB, userId, 'event'),
      liveRecords<Employer>(env.DB, userId, 'employer'),
    ]);
    const evs = expandAll(events, now - 3 * 86_400_000, now + 3 * 86_400_000);
    const notices = planNotices(tasks, evs, employers, now, WINDOW);
    if (!notices.length) continue;
    const subs = (await env.DB.prepare('SELECT id, endpoint, p256dh, auth FROM push_subscriptions WHERE user_id = ?').bind(userId).all<{ id: string; endpoint: string; p256dh: string; auth: string }>()).results;
    for (const n of notices) {
      const claimed = await env.DB.prepare('INSERT OR IGNORE INTO sent_notices (user_id, key, sent_at) VALUES (?, ?, ?)').bind(userId, n.key, now).run();
      if (!claimed.meta.changes) continue;
      for (const s of subs) {
        const r = await sendPush(s, { title: n.title, body: n.body, tag: n.key, target: n.target }, { publicKey: env.VAPID_PUBLIC_KEY!, privateJwk: env.VAPID_PRIVATE_JWK!, subject: env.VAPID_SUBJECT ?? 'mailto:admin@example.com' }, now).catch(() => 'error' as const);
        if (r === 'gone') await env.DB.prepare('DELETE FROM push_subscriptions WHERE id = ?').bind(s.id).run();
        else if (r === 'error') await env.DB.prepare('UPDATE push_subscriptions SET failures = failures + 1 WHERE id = ?').bind(s.id).run();
        else sent += 1;
      }
    }
  }
  await env.DB.prepare('DELETE FROM sent_notices WHERE sent_at < ?').bind(now - 14 * 86_400_000).run();
  return { sent };
}
