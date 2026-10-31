/** バックアップの整合性検証に使う、キー順を固定した JSON と SHA-256 */

export const SNAPSHOT_SCHEMA_VERSION = 2;

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
