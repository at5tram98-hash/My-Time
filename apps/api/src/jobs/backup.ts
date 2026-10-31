import {
  buildSnapshot, canonicalJson, compareRestore, dueOccurrences, eventRetention, isDue, snapshotRecords, SNAPSHOT_SCHEMA_VERSION, taskRetention, verifySnapshot,
  type CalEvent, type RestoreDiff, type SnapshotManifest, type Subtask, type Task,
} from '@my-time/domain';
import type { EntityName } from '@my-time/contracts';
import { applyUserZone, retentionMode, type Env } from '../env';
import { decryptSecret, newId } from '../lib/crypto';
import { Drive, GoogleError, refreshAccess } from '../lib/google';
import { logStmt, nextSeq, notify, resolveNotice, type RecordRow } from '../lib/store';

export const BACKUP_FOLDER = 'My Time Backup';
const ENTITIES: EntityName[] = ['calendar', 'event', 'task', 'subtask', 'subject', 'employer'];
/** 期限削除の前提：これより新しい検証済みの日次バックアップがあること */
const DAILY_FRESHNESS = 36 * 3_600_000;

const ymd = (t: number) => {
  // ファイル名は日本時間の日付
  const d = new Date(t + 9 * 3_600_000);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
};

/** 保存済みのリフレッシュトークンから Drive クライアントを作る。権限が取り消されていれば通知して null */
export async function driveFor(env: Env, userId: string, now: number): Promise<Drive | null> {
  const g = await env.DB.prepare('SELECT refresh_token_enc FROM oauth_grants WHERE user_id = ? AND revoked_at IS NULL').bind(userId).first<{ refresh_token_enc: string }>();
  if (!g || !env.TOKEN_ENC_KEY) return null;
  try {
    const tok = await refreshAccess(env, await decryptSecret(g.refresh_token_enc, env.TOKEN_ENC_KEY));
    return new Drive(env, tok.access_token);
  } catch (e) {
    if (e instanceof GoogleError && (e.status === 400 || e.status === 401)) {
      await env.DB.prepare('UPDATE oauth_grants SET revoked_at = ? WHERE user_id = ?').bind(now, userId).run();
      await notify(env.DB, userId, { level: 'error', kind: 'auth', key: 'auth:drive-revoked', title: 'Googleドライブの権限がありません', body: 'バックアップと期限削除を停止しています。「その他」からもう一度Googleでログインしてください。' }, now);
      return null;
    }
    throw e;
  }
}

async function allRows(db: D1Database, userId: string): Promise<RecordRow[]> {
  return (await db.prepare('SELECT * FROM records WHERE user_id = ? AND deleted = 0 AND restored_session_id IS NULL').bind(userId).all<RecordRow>()).results;
}

function rangeOf(rows: { entity: string; data: Record<string, unknown> }[]): { from: number | null; to: number | null } {
  const times: number[] = [];
  for (const r of rows) {
    const d = r.data;
    for (const k of ['start', 'end', 'plannedStart', 'plannedEnd', 'checkAt']) if (typeof d[k] === 'number') times.push(d[k] as number);
  }
  return times.length ? { from: Math.min(...times), to: Math.max(...times) } : { from: null, to: null };
}

interface UploadResult {
  manifestId: string;
  manifest: SnapshotManifest;
}

/** スナップショットを Drive に保存し、読み戻して検証できたときだけ verified にする */
async function uploadVerified(env: Env, drive: Drive, userId: string, kind: 'daily' | 'archive', tables: Record<string, Record<string, unknown>[]>, now: number): Promise<UploadResult> {
  const manifestId = newId();
  const flat = Object.entries(tables).flatMap(([entity, rs]) => rs.map((data) => ({ entity, data })));
  const { text, manifest } = await buildSnapshot({ schemaVersion: SNAPSHOT_SCHEMA_VERSION, kind, userId, createdAt: now, range: rangeOf(flat), tables });
  const name = `MyTime-${kind}-${ymd(now)}-${manifestId.slice(0, 8)}.json`;
  await env.DB.prepare('INSERT INTO backup_manifests (id, user_id, kind, created_at, drive_file_name, sha256, bytes, counts, schema_version, range_from, range_to, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
    .bind(manifestId, userId, kind, now, name, manifest.sha256, manifest.bytes, JSON.stringify(manifest.counts), manifest.schemaVersion, manifest.range.from, manifest.range.to, 'uploading')
    .run();
  try {
    const folder = await drive.findOrCreateFolder(BACKUP_FOLDER);
    const file = await drive.upload(folder, name, text, { mytimeKind: kind, mytimeSha256: manifest.sha256, mytimeManifest: manifestId });
    await env.DB.prepare('UPDATE backup_manifests SET drive_file_id = ? WHERE id = ?').bind(file.id, manifestId).run();
    // 書き込み成功だけでは信用しない：読み戻して件数・ハッシュ・スキーマ版を確認
    const back = await drive.download(file.id);
    const v = await verifySnapshot(back, manifest);
    if (!v.ok) throw new Error(`検証失敗：${v.reason}`);
    await env.DB.prepare("UPDATE backup_manifests SET status = 'verified', verified_at = ? WHERE id = ?").bind(now, manifestId).run();
    return { manifestId, manifest };
  } catch (e) {
    await env.DB.prepare("UPDATE backup_manifests SET status = 'failed', error = ? WHERE id = ?").bind(String(e instanceof Error ? e.message : e).slice(0, 500), manifestId).run();
    throw e;
  }
}

/**
 * 日次バックアップの中身：同期データ（現役のもの）＋ アプリ設定 ＋ 操作ログ ＋ 削除済みの印。
 * 設定と操作ログがあれば、新しい端末・新しいアカウントでも使い方ごと元に戻せ、
 * 削除済みの印があれば「消したはずのデータ」を復元時に誤って戻さない。
 */
async function dailyTables(env: Env, userId: string): Promise<Record<string, Record<string, unknown>[]>> {
  const rows = await allRows(env.DB, userId);
  const tables: Record<string, Record<string, unknown>[]> = Object.fromEntries(ENTITIES.map((e) => [e, []]));
  for (const r of rows) tables[r.entity]!.push({ ...(JSON.parse(r.data!) as Record<string, unknown>), __version: r.version });
  const st = await env.DB.prepare('SELECT data, updated_at FROM user_settings WHERE user_id = ?').bind(userId).first<{ data: string; updated_at: number }>();
  tables.settings = st ? [{ key: 'app', ...(JSON.parse(st.data) as Record<string, unknown>), __updatedAt: st.updated_at }] : [];
  tables.operationLog = (await env.DB.prepare('SELECT seq, at, entity, entity_id, action, detail FROM operation_log WHERE user_id = ? ORDER BY seq').bind(userId).all<Record<string, unknown>>()).results;
  tables.tombstones = (await env.DB.prepare('SELECT entity, id, version, delete_reason AS reason, updated_at FROM records WHERE user_id = ? AND deleted = 1 ORDER BY server_seq').bind(userId).all<Record<string, unknown>>()).results;
  return tables;
}

export async function runDailyBackup(env: Env, userId: string, now: number): Promise<{ ok: boolean; manifestId?: string; error?: string }> {
  const drive = await driveFor(env, userId, now);
  if (!drive) return { ok: false, error: 'Drive 未接続' };
  try {
    const tables = await dailyTables(env, userId);
    const { manifestId } = await uploadVerified(env, drive, userId, 'daily', tables, now);
    await resolveNotice(env.DB, userId, 'backup:failed', now);
    try {
      const q = await drive.quota();
      if (q.limit && q.usage / q.limit > 0.9) {
        await notify(env.DB, userId, { level: 'warn', kind: 'quota', key: 'quota:low', title: 'Googleドライブの空き容量が少なくなっています', body: `使用率 ${Math.round((q.usage / q.limit) * 100)}%。「バックアップ管理」から古いバックアップを整理できます。` }, now);
      } else await resolveNotice(env.DB, userId, 'quota:low', now);
    } catch {
      /* 容量の取得失敗はバックアップ自体の失敗にしない */
    }
    return { ok: true, manifestId };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await notify(env.DB, userId, { level: 'error', kind: 'backup', key: 'backup:failed', title: 'バックアップに失敗しました', body: `期限削除は保留しています。次回の自動実行で再試行します。（${msg.slice(0, 120)}）` }, now);
    return { ok: false, error: msg };
  }
}

const rangeAt = (entity: string, d: Record<string, unknown>): number | null =>
  (entity === 'event' || entity === 'occurrence' ? (d.start as number) : ((d.plannedStart as number | null) ?? (d.checkAt as number | null) ?? (d.createdAt as number | null))) ?? null;

export interface RetentionResult {
  purged: number;
  occurrences: number;
  skipped?: string;
  manifestId?: string;
}

/**
 * 30日削除と日付またぎ特則の物理削除。
 * 不変条件：検証済みの日次バックアップが新しいこと → 削除対象だけのアーカイブを Drive に保存し読み戻し検証 → その後に削除。
 * 途中で失敗したら1件も削除しない。復元閲覧中のデータは対象外。RETENTION_MODE が on 以外なら削除しない（dry-run は件数の記録のみ）。
 */
export async function runRetention(env: Env, userId: string, now: number): Promise<RetentionResult> {
  applyUserZone(env);
  // 本番の初期設定は「停止」。本物の Drive でバックアップと復元試験を確認してから on にする（docs/setup-cloudflare-google.md）
  const mode = retentionMode(env);
  if (mode === 'off') return { purged: 0, occurrences: 0, skipped: '期限削除は停止中（RETENTION_MODE=off）' };
  const latest = await env.DB.prepare("SELECT verified_at FROM backup_manifests WHERE user_id = ? AND kind = 'daily' AND status = 'verified' ORDER BY verified_at DESC LIMIT 1").bind(userId).first<{ verified_at: number }>();
  if (!latest || now - latest.verified_at > DAILY_FRESHNESS) return { purged: 0, occurrences: 0, skipped: '検証済みの新しいバックアップがありません' };

  const rows = await allRows(env.DB, userId);
  const parse = (r: RecordRow) => JSON.parse(r.data!) as Record<string, unknown>;
  const dueRows: RecordRow[] = [];
  const masters: { row: RecordRow; ev: CalEvent; starts: number[] }[] = [];
  const dueTaskIds = new Set<string>();
  for (const r of rows) {
    if (r.entity === 'event') {
      const ev = parse(r) as unknown as CalEvent;
      if (isDue(eventRetention(ev, now), now)) dueRows.push(r);
      else if (ev.recurrence) {
        const starts = dueOccurrences(ev, now);
        if (starts.length) masters.push({ row: r, ev, starts });
      }
    } else if (r.entity === 'task') {
      if (isDue(taskRetention(parse(r) as unknown as Task), now)) {
        dueRows.push(r);
        dueTaskIds.add(r.id);
      }
    }
  }
  for (const r of rows) if (r.entity === 'subtask' && dueTaskIds.has((parse(r) as unknown as Subtask).taskId)) dueRows.push(r);
  if (dueRows.length === 0 && masters.length === 0) return { purged: 0, occurrences: 0 };
  if (mode === 'dry-run') {
    // 試運転：何も保存・削除せず、対象の件数だけを記録して知らせる
    const occCount = masters.reduce((n, m) => n + m.starts.length, 0);
    await logStmt(env.DB, userId, now, 'retention', 'dry-run', 'dry-run', { candidates: dueRows.length, occurrences: occCount, ids: dueRows.slice(0, 50).map((r) => `${r.entity}:${r.id}`) }).run();
    await notify(env.DB, userId, { level: 'info', kind: 'purge', key: 'purge:dry-run', title: '期限削除の試運転', body: `有効にすると ${dueRows.length}件（繰り返しの${occCount}回）をアーカイブしてから削除します。現在は何も削除していません。` }, now);
    return { purged: 0, occurrences: 0, skipped: `試運転（対象 ${dueRows.length}件・繰り返し${occCount}回）` };
  }

  const drive = await driveFor(env, userId, now);
  if (!drive) return { purged: 0, occurrences: 0, skipped: 'Drive 未接続' };

  const tables: Record<string, Record<string, unknown>[]> = { event: [], task: [], subtask: [], occurrence: [] };
  for (const r of dueRows) tables[r.entity]!.push({ ...parse(r), __version: r.version });
  for (const m of masters) {
    const dur = m.ev.end - m.ev.start;
    for (const s of m.starts) {
      const x = m.ev.exceptions.find((e) => e.originalStart === s);
      tables.occurrence!.push({ id: `${m.ev.id}@${s}`, masterId: m.ev.id, originalStart: s, start: x?.start ?? s, end: x?.end ?? s + dur, title: x?.title ?? m.ev.title, notes: x?.notes ?? m.ev.notes, calendarId: m.ev.calendarId, timeZone: m.ev.timeZone, __version: m.row.version });
    }
  }

  let up: UploadResult;
  try {
    up = await uploadVerified(env, drive, userId, 'archive', tables, now);
  } catch (e) {
    await notify(env.DB, userId, { level: 'error', kind: 'purge', key: 'purge:archive-failed', title: '過去データのアーカイブに失敗しました', body: `期限を過ぎたデータの削除を保留しました。（${String(e instanceof Error ? e.message : e).slice(0, 120)}）` }, now);
    return { purged: 0, occurrences: 0, skipped: 'アーカイブ失敗' };
  }
  await resolveNotice(env.DB, userId, 'purge:archive-failed', now);

  const stmts: D1PreparedStatement[] = [];
  for (const [entity, rs] of Object.entries(tables)) {
    for (const d of rs) {
      stmts.push(env.DB.prepare('INSERT OR IGNORE INTO archive_entries (user_id, entity, id, version, manifest_id, range_at, archived_at) VALUES (?, ?, ?, ?, ?, ?, ?)').bind(userId, entity, d.id as string, d.__version as number, up.manifestId, rangeAt(entity, d), now));
    }
  }
  await env.DB.batch(stmts);

  // アーカイブした版のまま変わっていないものだけを削除（その間に端末から編集されたものは残す）
  let purged = 0;
  let seq = await nextSeq(env.DB, userId, dueRows.length + masters.length);
  seq -= dueRows.length + masters.length;
  const del: D1PreparedStatement[] = [];
  for (const r of dueRows) {
    seq += 1;
    del.push(
      env.DB.prepare("UPDATE records SET deleted = 1, delete_reason = 'purge', data = NULL, version = version + 1, server_seq = ? WHERE user_id = ? AND entity = ? AND id = ? AND version = ? AND deleted = 0 AND restored_session_id IS NULL RETURNING id").bind(seq, userId, r.entity, r.id, r.version),
      env.DB.prepare('INSERT INTO purge_ledger (user_id, entity, record_id, version, manifest_id, reason, purged_at) SELECT ?, ?, ?, ?, ?, ?, ? WHERE changes() > 0').bind(userId, r.entity, r.id, r.version, up.manifestId, '期限到来', now),
    );
  }
  let occ = 0;
  for (const m of masters) {
    seq += 1;
    const next: CalEvent = { ...m.ev, exceptions: [...m.ev.exceptions.filter((x) => !m.starts.includes(x.originalStart)), ...m.starts.map((s) => ({ originalStart: s, kind: 'archived' as const }))] };
    del.push(env.DB.prepare('UPDATE records SET data = ?, version = version + 1, server_seq = ? WHERE user_id = ? AND entity = ? AND id = ? AND version = ?').bind(JSON.stringify(next), seq, userId, 'event', m.row.id, m.row.version));
    occ += m.starts.length;
  }
  del.push(logStmt(env.DB, userId, now, 'retention', up.manifestId, 'purge', { candidates: dueRows.length, occurrences: occ }));
  const res = await env.DB.batch(del);
  for (let i = 0; i < dueRows.length; i++) purged += res[i * 2]!.results.length;
  return { purged, occurrences: occ, manifestId: up.manifestId };
}

// ---------------- 期間指定の復元（閲覧を終了するまで通常画面に表示） ----------------

export async function startRestore(env: Env, userId: string, from: number, to: number, now: number): Promise<{ sessionId: string; restored: number }> {
  applyUserZone(env);
  const entries = (await env.DB.prepare('SELECT DISTINCT a.manifest_id AS manifest_id, m.drive_file_id AS file_id, m.sha256, m.counts, m.schema_version, m.bytes, m.created_at FROM archive_entries a JOIN backup_manifests m ON m.id = a.manifest_id WHERE a.user_id = ? AND a.range_at >= ? AND a.range_at < ? AND m.status = ?')
    .bind(userId, from, to, 'verified')
    .all<{ manifest_id: string; file_id: string; sha256: string; counts: string; schema_version: number; bytes: number; created_at: number }>()).results;
  const sessionId = newId();
  await env.DB.prepare('INSERT INTO restoration_sessions (id, user_id, range_from, range_to, created_at) VALUES (?, ?, ?, ?, ?)').bind(sessionId, userId, from, to, now).run();
  if (entries.length === 0) return { sessionId, restored: 0 };
  const drive = await driveFor(env, userId, now);
  if (!drive) throw new Error('Googleドライブに接続できません');
  let restored = 0;
  for (const m of entries) {
    const text = await drive.download(m.file_id);
    const v = await verifySnapshot(text, { schemaVersion: m.schema_version, kind: 'archive', createdAt: m.created_at, counts: JSON.parse(m.counts) as Record<string, number>, sha256: m.sha256, bytes: m.bytes, range: { from: null, to: null } });
    if (!v.ok || !v.body) throw new Error(`アーカイブの検証に失敗しました（${v.reason}）`);
    const stmts: D1PreparedStatement[] = [];
    for (const [entity, list] of Object.entries(v.body.tables)) {
      for (const raw of list) {
        const at = rangeAt(entity, raw);
        if (at == null || at < from || at >= to) continue;
        const { __version: _v, masterId: _m, originalStart: _o, ...rest } = raw as Record<string, unknown>;
        const target = entity === 'occurrence' ? 'event' : entity;
        const record = entity === 'occurrence' ? { ...rest, recurrence: null, exceptions: [], classInfo: null, employerId: null, hideAfterEnd: false, source: null, createdAt: now, updatedAt: now } : rest;
        const id = record.id as string;
        const cur = await env.DB.prepare('SELECT version, deleted FROM records WHERE user_id = ? AND entity = ? AND id = ?').bind(userId, target, id).first<{ version: number; deleted: number }>();
        if (cur && cur.deleted === 0) continue; // 同じIDの現役データがあれば上書きしない
        const seq = await nextSeq(env.DB, userId);
        stmts.push(
          env.DB.prepare(
            `INSERT INTO records (user_id, entity, id, version, data, deleted, delete_reason, updated_at, server_seq, restored_session_id) VALUES (?1, ?2, ?3, ?4, ?5, 0, NULL, ?6, ?7, ?8)
             ON CONFLICT(user_id, entity, id) DO UPDATE SET version = ?4, data = ?5, deleted = 0, delete_reason = NULL, updated_at = ?6, server_seq = ?7, restored_session_id = ?8`,
          ).bind(userId, target, id, (cur?.version ?? 0) + 1, JSON.stringify(record), (record.updatedAt as number) ?? now, seq, sessionId),
        );
        restored += 1;
      }
    }
    if (stmts.length) await env.DB.batch(stmts);
  }
  await env.DB.batch([
    env.DB.prepare('UPDATE restoration_sessions SET restored_count = ? WHERE id = ?').bind(restored, sessionId),
    logStmt(env.DB, userId, now, 'restore', sessionId, 'start', { from, to, restored }),
  ]);
  return { sessionId, restored };
}

/** 「閲覧を終了」：復元で戻したデータだけを再び通常データから外す（Drive の原本は残す） */
export async function endRestore(env: Env, userId: string, sessionId: string, now: number): Promise<number> {
  const rows = (await env.DB.prepare('SELECT entity, id FROM records WHERE user_id = ? AND restored_session_id = ? AND deleted = 0').bind(userId, sessionId).all<{ entity: string; id: string }>()).results;
  const stmts: D1PreparedStatement[] = [];
  for (const r of rows) {
    const seq = await nextSeq(env.DB, userId);
    stmts.push(env.DB.prepare("UPDATE records SET deleted = 1, delete_reason = 'restore-end', data = NULL, version = version + 1, server_seq = ? WHERE user_id = ? AND entity = ? AND id = ? AND restored_session_id = ?").bind(seq, userId, r.entity, r.id, sessionId));
  }
  stmts.push(env.DB.prepare('UPDATE restoration_sessions SET ended_at = ? WHERE id = ? AND user_id = ?').bind(now, sessionId, userId));
  stmts.push(logStmt(env.DB, userId, now, 'restore', sessionId, 'end', { removed: rows.length }));
  await env.DB.batch(stmts);
  return rows.length;
}

// ---------------- 復元試験（本物の Drive で、保存したファイルから正しく戻せるかを確かめる） ----------------

export interface RestoreDrillResult extends RestoreDiff {
  manifestId: string;
  kind: string;
  /** バックアップに含まれる設定・操作ログ・削除済みの印の件数 */
  extras: { settings: number; operationLog: number; tombstones: number };
}

/**
 * 指定したバックアップを Drive から読み戻し、検証してから「復元したら得られる記録」を作り、
 * 現在のサーバーのデータと1件ずつ比べる。データは書き換えない（読み取りだけ）。
 * バックアップ直後なら完全一致するはず。差があれば「バックアップ後に変わった記録」として件数を返す。
 */
export async function restoreDrill(env: Env, userId: string, manifestId: string, now: number): Promise<RestoreDrillResult> {
  const m = await env.DB.prepare("SELECT kind, drive_file_id, sha256, counts, schema_version, bytes, created_at, range_from, range_to FROM backup_manifests WHERE id = ? AND user_id = ? AND status = 'verified'")
    .bind(manifestId, userId)
    .first<{ kind: 'daily' | 'archive'; drive_file_id: string; sha256: string; counts: string; schema_version: number; bytes: number; created_at: number; range_from: number | null; range_to: number | null }>();
  if (!m) throw new Error('検証済みのバックアップが見つかりません');
  const drive = await driveFor(env, userId, now);
  if (!drive) throw new Error('Googleドライブに接続できません');
  const text = await drive.download(m.drive_file_id);
  const v = await verifySnapshot(text, { schemaVersion: m.schema_version, kind: m.kind, createdAt: m.created_at, counts: JSON.parse(m.counts) as Record<string, number>, sha256: m.sha256, bytes: m.bytes, range: { from: m.range_from, to: m.range_to } });
  if (!v.ok || !v.body) throw new Error(`読み戻したファイルの検証に失敗しました（${v.reason}）`);
  const restored = snapshotRecords(v.body);
  const current = new Map<string, { version: number | null; json: string }>();
  if (m.kind === 'daily') {
    for (const r of await allRows(env.DB, userId)) current.set(`${r.entity}:${r.id}`, { version: r.version, json: canonicalJson(JSON.parse(r.data!)) });
  } else {
    // アーカイブは「削除する直前の内容」と比べる：記録した版と同じ版のまま削除されたかを確認
    for (const k of restored.keys()) {
      const [entity, id] = [k.slice(0, k.indexOf(':')), k.slice(k.indexOf(':') + 1)];
      const a = await env.DB.prepare('SELECT version FROM archive_entries WHERE user_id = ? AND manifest_id = ? AND entity = ? AND id = ?').bind(userId, manifestId, entity, id).first<{ version: number }>();
      if (a) current.set(k, { version: a.version, json: restored.get(k)!.json });
    }
  }
  const diff = compareRestore(restored, current);
  const extras = { settings: v.body.tables.settings?.length ?? 0, operationLog: v.body.tables.operationLog?.length ?? 0, tombstones: v.body.tables.tombstones?.length ?? 0 };
  await logStmt(env.DB, userId, now, 'backup', manifestId, 'restore-drill', { ok: diff.ok, matched: diff.matched, missing: diff.missingNow.length, extra: diff.extraNow.length, changed: diff.changed.length }).run();
  return { manifestId, kind: m.kind, ...diff, extras };
}
