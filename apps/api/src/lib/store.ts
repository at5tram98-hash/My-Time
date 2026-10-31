import type { EntityName } from '@my-time/contracts';
import { newId } from './crypto';

export interface RecordRow {
  user_id: string;
  entity: EntityName;
  id: string;
  version: number;
  data: string | null;
  deleted: number;
  delete_reason: string | null;
  updated_at: number;
  server_seq: number;
  restored_session_id: string | null;
}

/** ユーザーごとの単調増加カーソル（pull の位置） */
export async function nextSeq(db: D1Database, userId: string, n = 1): Promise<number> {
  const r = await db
    .prepare('INSERT INTO sync_seq (user_id, seq) VALUES (?1, ?2) ON CONFLICT(user_id) DO UPDATE SET seq = seq + ?2 RETURNING seq')
    .bind(userId, n)
    .first<{ seq: number }>();
  return r!.seq;
}

export function getRecord(db: D1Database, userId: string, entity: string, id: string): Promise<RecordRow | null> {
  return db.prepare('SELECT * FROM records WHERE user_id = ? AND entity = ? AND id = ?').bind(userId, entity, id).first<RecordRow>();
}

export async function liveRecords<T = Record<string, unknown>>(db: D1Database, userId: string, entity: EntityName, opts: { includeRestored?: boolean } = {}): Promise<T[]> {
  const rows = await db
    .prepare(`SELECT data FROM records WHERE user_id = ? AND entity = ? AND deleted = 0 ${opts.includeRestored ? '' : 'AND restored_session_id IS NULL'}`)
    .bind(userId, entity)
    .all<{ data: string }>();
  return rows.results.map((r) => JSON.parse(r.data) as T);
}

export function logStmt(db: D1Database, userId: string, at: number, entity: string, entityId: string, action: string, detail?: unknown) {
  return db.prepare('INSERT INTO operation_log (user_id, at, entity, entity_id, action, detail) VALUES (?, ?, ?, ?, ?, ?)').bind(userId, at, entity, entityId, action, detail == null ? null : JSON.stringify(detail));
}

/**
 * 「その他 > お知らせ」に出す通知。同じ dedupe_key は1件にまとめ、繰り返しの警告で溢れさせない。
 * 既に解決済みのものが再発した場合だけ未解決に戻す。
 */
export async function notify(db: D1Database, userId: string, n: { level: 'info' | 'warn' | 'error'; kind: string; title: string; body: string; key: string }, now: number): Promise<void> {
  await db
    .prepare(
      `INSERT INTO notifications (id, user_id, level, kind, title, body, dedupe_key, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(user_id, dedupe_key) DO UPDATE SET body = excluded.body, level = excluded.level, title = excluded.title,
         created_at = CASE WHEN resolved_at IS NOT NULL THEN excluded.created_at ELSE created_at END,
         read_at = CASE WHEN resolved_at IS NOT NULL THEN NULL ELSE read_at END,
         resolved_at = NULL`,
    )
    .bind(newId(), userId, n.level, n.kind, n.title, n.body, n.key, now)
    .run();
}

export async function resolveNotice(db: D1Database, userId: string, key: string, now: number): Promise<void> {
  await db.prepare('UPDATE notifications SET resolved_at = ? WHERE user_id = ? AND dedupe_key = ? AND resolved_at IS NULL').bind(now, userId, key).run();
}
