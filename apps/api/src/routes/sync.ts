import { Hono } from 'hono';
import { ENTITY_SCHEMAS, pushRequestSchema, type PullChange, type PullResult, type PushResult, type SyncOp } from '@my-time/contracts';
import type { AppBindings } from '../env';
import { getRecord, logStmt, type RecordRow } from '../lib/store';

export const syncRoutes = new Hono<AppBindings>();

type OpResult = PushResult['results'][number];
type DeleteReason = NonNullable<OpResult['deleteReason']>;

/**
 * 端末の未同期キューを受け取って反映する。
 * - opId による冪等：同じ操作の再送（通信断・再試行）は二重に反映しない
 * - 削除（tombstone）は最優先：ユーザー削除・期限削除・復元閲覧の終了で消えた記録は、
 *   端末側の更新日時や baseVersion に関係なく put で再作成・復活させない（復元は /restore API だけが行う）
 * - version による衝突検出：端末が見た版とサーバーの版が違えば、updatedAt が新しい方を採用し、古い側は conflict として返す
 * - 書き込みは「読んだ版のまま」のときだけ成功する条件付き更新。期限削除などと同時に走っても、
 *   間に入った変更（特に削除）を上書きしない。条件が外れたら読み直して判定をやり直す
 */
export async function applyOp(db: D1Database, userId: string, op: SyncOp, now: number): Promise<OpResult> {
  const receipt = await db.prepare('SELECT status, version, result_json FROM sync_receipts WHERE user_id = ? AND op_id = ?').bind(userId, op.opId).first<{ status: string; version: number; result_json: string | null }>();
  if (receipt) {
    if (receipt.result_json) return JSON.parse(receipt.result_json) as OpResult;
    // Old receipts lack the conflict payload. Re-read authoritative state.
    if (receipt.status === 'conflict') {
      const cur = await getRecord(db, userId, op.entity, op.entityId);
      return { opId: op.opId, status: 'conflict', version: cur?.version ?? receipt.version,
        serverRecord: cur?.data ? JSON.parse(cur.data) : null, serverDeleted: cur?.deleted === 1,
        deleteReason: (cur?.delete_reason as DeleteReason) ?? null };
    }
    return { opId: op.opId, status: 'duplicate', version: receipt.version };
  }

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

  const receiptStmt = (status: string, version: number, result?: OpResult) =>
    db.prepare('INSERT INTO sync_receipts (user_id, op_id, status, version, created_at, result_json) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT DO NOTHING').bind(userId, op.opId, status, version, now, result ? JSON.stringify(result) : null);

  for (let attempt = 0; attempt < 3; attempt++) {
    const cur = await getRecord(db, userId, op.entity, op.entityId);

    // 1) 削除済み（tombstone）は端末の内容より常に優先
    if (cur && cur.deleted === 1) {
      if (op.op === 'delete') {
        await receiptStmt('applied', cur.version).run();
        return { opId: op.opId, status: 'applied', version: cur.version };
      }
      const result: OpResult = { opId: op.opId, status: 'conflict', version: cur.version, serverRecord: null, serverDeleted: true, deleteReason: (cur.delete_reason as DeleteReason | null) ?? 'user' };
      await db.batch([receiptStmt('conflict', cur.version, result), logStmt(db, userId, now, op.entity, op.entityId, 'put-refused', { reason: 'tombstone', deleteReason: cur.delete_reason, base: op.baseVersion })]);
      return result;
    }

    // 2) 版の衝突：サーバー側の方が新しければ反映しない
    const curVersion = cur?.version ?? 0;
    const conflicted = curVersion !== op.baseVersion;
    if (conflicted && cur && cur.updated_at > updatedAt) {
      const result: OpResult = { opId: op.opId, status: 'conflict', version: cur.version, serverRecord: cur.data ? JSON.parse(cur.data) : null };
      await receiptStmt('conflict', cur.version, result).run();
      return result;
    }

    // 3) 読んだ版のままのときだけ書く（復元閲覧中の印 restored_session_id はここでは変えない）
    const version = curVersion + 1;
    const seq = 0; // database triggers assign the committed cursor
    const del = op.op === 'delete' ? 1 : 0;
    const write = cur
      ? db
          .prepare('UPDATE records SET version = ?, data = ?, deleted = ?, delete_reason = ?, updated_at = ?, server_seq = ? WHERE user_id = ? AND entity = ? AND id = ? AND version = ? AND deleted = 0 AND NOT EXISTS (SELECT 1 FROM sync_receipts WHERE user_id = ? AND op_id = ?)')
          .bind(version, data, del, del ? 'user' : null, updatedAt, seq, userId, op.entity, op.entityId, curVersion, userId, op.opId)
      : db
          .prepare('INSERT INTO records (user_id, entity, id, version, data, deleted, delete_reason, updated_at, server_seq, restored_session_id) SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL WHERE NOT EXISTS (SELECT 1 FROM sync_receipts WHERE user_id = ? AND op_id = ?) ON CONFLICT(user_id, entity, id) DO NOTHING')
          .bind(userId, op.entity, op.entityId, version, data, del, del ? 'user' : null, updatedAt, seq, userId, op.opId);
    // 受領記録と操作ログは「この書き込みが実際に入ったとき」だけ残す（server_seq はこの操作だけの値）
    const [w] = await db.batch([
      write,
      db.prepare(`INSERT INTO sync_receipts (user_id, op_id, status, version, created_at) SELECT ?, ?, 'applied', ?, ? WHERE changes() > 0 ON CONFLICT DO NOTHING`).bind(userId, op.opId, version, now),
      db
        .prepare(`INSERT INTO operation_log (user_id, at, entity, entity_id, action, detail) SELECT ?, ?, ?, ?, ?, ? WHERE changes() > 0`)
        .bind(userId, now, op.entity, op.entityId, del ? 'delete' : 'put', conflicted ? JSON.stringify({ conflict: true, base: op.baseVersion, server: curVersion }) : null),
    ]);
    if ((w?.meta.changes ?? 0) > 0) return { opId: op.opId, status: 'applied', version };
    // 読んだ直後に別の処理（期限削除・他端末）が書き換えた：読み直して判定し直す
  }
  // 3回とも競合した場合は端末の変更を捨てず、次回の同期で再送してもらう
  return { opId: op.opId, status: 'retry', version: 0, reason: '同時に更新されたため、次回の同期で再送します' };
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
  const generation = await c.env.DB.prepare('SELECT generation FROM sync_seq WHERE user_id = ?').bind(c.get('userId')).first<{ generation: string }>();
  const res: PullResult = { generation: generation?.generation ?? 'initial', cursor: page.at(-1)?.server_seq ?? cursor, changes: page.map(toChange), hasMore: rows.results.length > limit };
  return c.json(res);
});
