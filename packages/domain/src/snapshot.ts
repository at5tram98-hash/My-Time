/** バックアップの整合性検証に使う、キー順を固定した JSON と SHA-256 */

/**
 * 4：アカウント識別・アーカイブ索引・受領記録も含む（認証情報は除外）。
 * 3：日次バックアップにアプリ設定（settings）・操作ログ（operationLog）・削除済みの印（tombstones）を追加。
 * 復元は版 2 のアーカイブも読める（件数・ハッシュの検証は版によらない）。
 */
export const SNAPSHOT_SCHEMA_VERSION = 4;

/** 同期対象の記録の種類（バックアップの中で「データ」として復元するもの） */
export const RECORD_TABLES = ['calendar', 'event', 'task', 'subtask', 'subject', 'employer'] as const;

export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  const obj = value as Record<string, unknown>;
  return `{${Object.keys(obj)
    .filter((k) => obj[k] !== undefined)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${canonicalJson(obj[k])}`)
    .join(',')}}`;
}

export async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export interface SnapshotBody {
  schemaVersion: number;
  kind: 'daily' | 'archive';
  userId: string;
  createdAt: number;
  /** 含まれるデータの期間（予定・タスクの最小〜最大日時） */
  range: { from: number | null; to: number | null };
  tables: Record<string, Record<string, unknown>[]>;
}

export interface SnapshotManifest {
  schemaVersion: number;
  kind: 'daily' | 'archive';
  createdAt: number;
  counts: Record<string, number>;
  sha256: string;
  bytes: number;
  range: { from: number | null; to: number | null };
}

export async function buildSnapshot(body: SnapshotBody): Promise<{ text: string; manifest: SnapshotManifest }> {
  const text = canonicalJson(body);
  return {
    text,
    manifest: {
      schemaVersion: body.schemaVersion,
      kind: body.kind,
      createdAt: body.createdAt,
      counts: Object.fromEntries(Object.entries(body.tables).map(([k, v]) => [k, v.length])),
      sha256: await sha256Hex(text),
      bytes: new TextEncoder().encode(text).length,
      range: body.range,
    },
  };
}

/** 保存したファイルを読み戻し、件数・ハッシュ・スキーマ版が一致するか検証する（一致して初めて成功扱い） */
export async function verifySnapshot(text: string, manifest: SnapshotManifest): Promise<{ ok: boolean; reason?: string; body?: SnapshotBody }> {
  if ((await sha256Hex(text)) !== manifest.sha256) return { ok: false, reason: 'ハッシュが一致しません' };
  let body: SnapshotBody;
  try {
    body = JSON.parse(text) as SnapshotBody;
  } catch {
    return { ok: false, reason: 'JSONとして読めません' };
  }
  if (body.schemaVersion !== manifest.schemaVersion) return { ok: false, reason: 'スキーマ版が一致しません' };
  for (const [k, n] of Object.entries(manifest.counts)) {
    if ((body.tables[k]?.length ?? -1) !== n) return { ok: false, reason: `${k} の件数が一致しません` };
  }
  return { ok: true, body };
}

/**
 * スナップショットから「復元したらこうなる」記録の集合を作る（復元試験用）。
 * キーは `${entity}:${id}`、値は版と内容（キー順を固定した JSON）。
 */
export function snapshotRecords(body: Pick<SnapshotBody, 'tables'>): Map<string, { version: number | null; json: string }> {
  const out = new Map<string, { version: number | null; json: string }>();
  for (const entity of RECORD_TABLES) {
    for (const raw of body.tables[entity] ?? []) {
      const { __version, ...rec } = raw as Record<string, unknown> & { __version?: number };
      out.set(`${entity}:${rec.id as string}`, { version: typeof __version === 'number' ? __version : null, json: canonicalJson(rec) });
    }
  }
  return out;
}

export interface RestoreDiff {
  ok: boolean;
  /** 一致した記録の数 */
  matched: number;
  /** バックアップにあるが現在はない（バックアップ後に削除された） */
  missingNow: string[];
  /** 現在あるがバックアップにない（バックアップ後に作成された） */
  extraNow: string[];
  /** 内容が違う（バックアップ後に変更された） */
  changed: string[];
}

/** 復元結果と比較対象（現在のデータや削除前のデータ）が一致するかを調べる */
export function compareRestore(restored: Map<string, { version: number | null; json: string }>, current: Map<string, { version: number | null; json: string }>): RestoreDiff {
  const missingNow: string[] = [];
  const changed: string[] = [];
  let matched = 0;
  for (const [k, v] of restored) {
    const c = current.get(k);
    if (!c) missingNow.push(k);
    else if (c.json !== v.json || (v.version != null && c.version != null && c.version !== v.version)) changed.push(k);
    else matched += 1;
  }
  const extraNow = [...current.keys()].filter((k) => !restored.has(k));
  return { ok: missingNow.length === 0 && extraNow.length === 0 && changed.length === 0, matched, missingNow, extraNow, changed };
}
