import { expandAll, planNotices, type CalEvent, type Employer, type NoticePrefs, type Task } from '@my-time/domain';
import { pushConfigured, applyUserZone, type Env } from '../env';
import { liveRecords } from '../lib/store';
import { sendPush } from '../lib/webpush';

const WINDOW = 30 * 60_000; // 5分ごとの Cron + 余裕

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
    const notices = planNotices(tasks, evs, employers, now, WINDOW, await noticePrefs(env, userId));
    if (!notices.length) continue;
    const subs = (await env.DB.prepare('SELECT id, endpoint, p256dh, auth FROM push_subscriptions WHERE user_id = ?').bind(userId).all<{ id: string; endpoint: string; p256dh: string; auth: string }>()).results;
    for (const n of notices) {
      for (const s of subs) {
        const key = `${n.key}:sub:${s.id}`;
        const claimed = await env.DB.prepare('INSERT OR IGNORE INTO sent_notices (user_id, key, sent_at) VALUES (?, ?, ?)').bind(userId, key, now).run();
        if (!claimed.meta.changes) continue;
        const r = await sendPush(s, { title: n.title, body: n.body, tag: n.key, target: n.target }, { publicKey: env.VAPID_PUBLIC_KEY!, privateJwk: env.VAPID_PRIVATE_JWK!, subject: env.VAPID_SUBJECT ?? 'mailto:admin@example.com' }, now).catch(() => 'error' as const);
        if (r === 'gone') await env.DB.prepare('DELETE FROM push_subscriptions WHERE id = ?').bind(s.id).run();
        else if (r === 'error') {
          await env.DB.prepare('UPDATE push_subscriptions SET failures = failures + 1 WHERE id = ?').bind(s.id).run();
          await env.DB.prepare('DELETE FROM sent_notices WHERE user_id = ? AND key = ?').bind(userId, key).run();
        } else sent += 1;
      }
    }
  }
  await env.DB.prepare('DELETE FROM sent_notices WHERE sent_at < ?').bind(now - 14 * 86_400_000).run();
  return { sent };
}

/** 端末から同期した設定の静穏時間・出発通知（P42・P43）。設定がなければ従来どおり */
async function noticePrefs(env: Env, userId: string): Promise<NoticePrefs | undefined> {
  const row = await env.DB.prepare('SELECT data FROM user_settings WHERE user_id = ?').bind(userId).first<{ data: string }>().catch(() => null);
  if (!row) return undefined;
  try {
    const s = JSON.parse(row.data) as Record<string, unknown>;
    const n = (v: unknown) => (typeof v === 'number' && v >= 0 && v <= 24 ? v : null);
    return { quietFrom: n(s.quietFrom), quietTo: n(s.quietTo), quietAllowImportant: s.quietAllowImportant !== false, departure: s.departureNotify === true };
  } catch {
    return undefined;
  }
}
