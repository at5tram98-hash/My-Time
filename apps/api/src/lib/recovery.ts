import { ENTITY_NAMES, ENTITY_SCHEMAS } from '@my-time/contracts';
import { canonicalJson, type SnapshotBody } from '@my-time/domain';

/** Rehydrate a verified daily snapshot into an empty, isolated D1 target.
 * No credentials, sessions, grants or Push subscriptions are copied.
 * The target is explicit; this is also used by the disaster-recovery test.
 */
export async function recoverSnapshot(target: D1Database, userId: string, body: SnapshotBody): Promise<void> {
  if (body.kind !== 'daily' || body.userId !== userId || body.schemaVersion !== 3) throw new Error('復旧対象のアカウント・形式が一致しません');
  const occupied = await target.prepare('SELECT (SELECT COUNT(*) FROM records WHERE user_id = ?1) + (SELECT COUNT(*) FROM user_settings WHERE user_id = ?1) + (SELECT COUNT(*) FROM operation_log WHERE user_id = ?1) AS n').bind(userId).first<{ n: number }>();
  if (occupied?.n) throw new Error('復旧先は空である必要があります');
  const stmts: D1PreparedStatement[] = [];
  const seen = new Set<string>();
  for (const entity of ENTITY_NAMES) {
    for (const raw of body.tables[entity] ?? []) {
      const { __version, ...record } = raw;
      const parsed = ENTITY_SCHEMAS[entity].parse(record);
      if (!Number.isSafeInteger(__version) || (__version as number) < 1) throw new Error('復旧データの版が不正です');
      const key = `${entity}:${parsed.id}`;
      if (seen.has(key)) throw new Error('復旧IDが重複しています');
      seen.add(key);
      stmts.push(target.prepare('INSERT INTO records(user_id, entity, id, version, data, deleted, updated_at, server_seq) VALUES (?, ?, ?, ?, ?, 0, ?, 0)').bind(userId, entity, parsed.id, __version as number, canonicalJson(parsed), parsed.updatedAt));
    }
  }
  for (const raw of body.tables.tombstones ?? []) {
    const entity = raw.entity as typeof ENTITY_NAMES[number];
    if (!ENTITY_NAMES.includes(entity) || typeof raw.id !== 'string' || !Number.isSafeInteger(raw.version) || !['user', 'purge', 'restore-end'].includes(raw.reason as string)) throw new Error('削除の印が不正です');
    const key = `${entity}:${raw.id}`;
    if (seen.has(key)) throw new Error('現役データと削除の印が重複しています');
    seen.add(key);
    stmts.push(target.prepare('INSERT INTO records(user_id, entity, id, version, data, deleted, delete_reason, updated_at, server_seq) VALUES (?, ?, ?, ?, NULL, 1, ?, ?, 0)').bind(userId, entity, raw.id, raw.version as number, raw.reason as string, raw.updated_at as number));
  }
  for (const raw of body.tables.settings ?? []) {
    const { key: _key, __updatedAt, ...settings } = raw;
    stmts.push(target.prepare('INSERT INTO user_settings(user_id, data, updated_at) VALUES (?, ?, ?)').bind(userId, canonicalJson(settings), __updatedAt as number));
  }
  for (const raw of body.tables.operationLog ?? []) {
    stmts.push(target.prepare('INSERT INTO operation_log(user_id, at, entity, entity_id, action, detail) VALUES (?, ?, ?, ?, ?, ?)').bind(userId, raw.at as number, raw.entity as string, raw.entity_id as string, raw.action as string, raw.detail as string | null));
  }
  if (stmts.length) await target.batch(stmts);
}
