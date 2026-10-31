import { Hono } from 'hono';
import { ENTITY_SCHEMAS, pushRequestSchema, type PullChange, type PullResult, type PushResult, type SyncOp } from '@my-time/contracts';
import type { AppBindings } from '../env';
import { getRecord, logStmt, nextSeq, type RecordRow } from '../lib/store';

export const syncRoutes = new Hono<AppBindings>();

/**
 * 端末の未同期キューを受け取って反映する。
 * - opId による冪等：同じ操作の再送（通信断・再試行）は二重に反映しない
 * - version による衝突検出：端末が見た版とサーバーの版が違えば、updatedAt が新しい方を採用し、古い側は conflict として返す
 * - すべての書き込みは1つの batch（D1 のトランザクション）で行う
 */
export async function applyOp(db: D1Database, userId: string, op: SyncOp, now: number): Promise<PushResult['results'][number]> {
  const receipt = await db.prepare('SELECT status, version FROM sync_receipts WHERE user_id = ? AND op_id = ?').bind(userId, op.opId).first<{ status: string; version: number }>();
  if (receipt) return { opId: op.opId, status: 'duplicate', version: receipt.version };

  let data: string | null = null;
  let updatedAt = op.clientUpdatedAt;
  if (op.op === 'put') {
    const parsed = ENTITY_SCHEMAS[op.entity].safeParse(op.record);
    if (!parsed.success || (parsed.data as { id: string }).id !== op.entityId) {
      return { opId: op.opId, status: 'rejected', version: 0, reason: parsed.success ? 'id が一致しません' : parsed.error.issues[0]?.message ?? '検証エラー' };
    }
    data = JSON.stringify(parsed.data);
    updatedAt = (parsed.data as { updatedAt: number }).updatedAt;
  }

  const cur = await getRecord(db, userId, op.entity, op.entityId);
  const curVersion = cur?.version ?? 0;
  let conflicted = false;
  if (curVersion !== op.baseVersion) {
    conflicted = true;
    // 端末側の変更の方が古ければ反映せず、サーバーの最新を返す（端末はそれで上書きする）
    if (cur && cur.updated_at > updatedAt) {
      await db.prepare('INSERT INTO sync_receipts (user_id, op_id, status, version, created_at) VALUES (?, ?, ?, ?, ?)').bind(userId, op.opId, 'conflict', cur.version, now).run();
      return { opId: op.opId, status: 'conflict', version: cur.version, serverRecord: cur.data ? (JSON.parse(cur.data) as Record<string, unknown>) : null };
    }
  }
  const version = curVersion + 1;
  const seq = await nextSeq(db, userId);
  await db.batch([
    db
      .prepare(
        `INSERT INTO records (user_id, entity, id, version, data, deleted, delete_reason, updated_at, server_seq, restored_session_id)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, NULL)
         ON CONFLICT(user_id, entity, id) DO UPDATE SET version = ?4, data = ?5, deleted = ?6, delete_reason = ?7, updated_at = ?8, server_seq = ?9, restored_session_id = NULL`,
      )
      .bind(userId, op.entity, op.entityId, version, data, op.op === 'delete' ? 1 : 0, op.op === 'delete' ? 'user' : null, updatedAt, seq),
    db.prepare('INSERT INTO sync_receipts (user_id, op_id, status, version, created_at) VALUES (?, ?, ?, ?, ?)').bind(userId, op.opId, 'applied', version, now),
    logStmt(db, userId, now, op.entity, op.entityId, op.op === 'delete' ? 'delete' : 'put', conflicted ? { conflict: true, base: op.baseVersion, server: curVersion } : null),
  ]);
  return { opId: op.opId, status: 'applied', version };
}

syncRoutes.post('/push', async (c) => {
  const parsed = pushRequestSchema.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: '形式が不正です' }, 400);
  const results: PushResult['results'] = [];
  for (const op of parsed.data.ops) results.push(await applyOp(c.env.DB, c.get('userId'), op, c.get('now')));
  return c.json({ results } satisfies PushResult);
});

export function toChange(r: RecordRow): PullChange {
  return {
    entity: r.entity,
    id: r.id,
    version: r.version,
    deleted: r.deleted === 1,
    reason: (r.delete_reason as PullChange['reason']) ?? null,
    record: r.data ? (JSON.parse(r.data) as Record<string, unknown>) : null,
    restoredSessionId: r.restored_session_id,
  };
}

syncRoutes.get('/pull', async (c) => {
  const cursor = Math.max(0, Number(c.req.query('cursor') ?? 0) || 0);
  const limit = 500;
  const rows = await c.env.DB.prepare('SELECT * FROM records WHERE user_id = ? AND server_seq > ? ORDER BY server_seq LIMIT ?').bind(c.get('userId'), cursor, limit + 1).all<RecordRow>();
  const page = rows.results.slice(0, limit);
  const res: PullResult = { cursor: page.at(-1)?.server_seq ?? cursor, changes: page.map(toChange), hasMore: rows.results.length > limit };
  return c.json(res);
});
