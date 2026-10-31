import type Dexie from 'dexie';
import { ENTITY_SCHEMAS, ENTITY_NAMES } from '@my-time/contracts';
import { canonicalJson, defaultCalendars, newId, normalizeCalendar, normalizeEvent, normalizeTask, sha256Hex } from '@my-time/domain';
import { DATA_TABLES } from './accounts';
import { DEFAULT_SETTINGS, ownerOf, type MyTimeDB } from './db';

const FORMAT = 'my-time-device-transfer';
const MAX_BYTES = 50 * 1024 * 1024;
type Row = Record<string, unknown>;
interface TransferBody {
  format: typeof FORMAT;
  version: 1;
  owner: string | null;
  origin: string;
  createdAt: number;
  tables: Record<string, Row[]>;
}
export interface DeviceTransfer { body: TransferBody; sha256: string }
const normalizers = { calendar: normalizeCalendar, event: normalizeEvent, task: normalizeTask };
const table = (db: MyTimeDB, name: string) => db.table(name) as Dexie.Table<Row, string>;

/** One read transaction gives a consistent snapshot, including pending edits and recovery copies. */
export async function exportDevice(db: MyTimeDB, origin: string, now = Date.now()): Promise<string> {
  const tables = await db.transaction('r', db.tables, async () => {
    const entries = await Promise.all(db.tables.map(async (t) => [t.name, await t.toArray()] as const));
    return Object.fromEntries(entries) as Record<string, Row[]>;
  });
  const body: TransferBody = { format: FORMAT, version: 1, owner: ownerOf(db.name), origin, createdAt: now, tables };
  return JSON.stringify({ body, sha256: await sha256Hex(canonicalJson(body)) });
}

export async function readDevice(text: string): Promise<DeviceTransfer> {
  if (new TextEncoder().encode(text).length > MAX_BYTES) throw new Error('移行ファイルが大きすぎます（上限50MB）');
  const file = JSON.parse(text) as DeviceTransfer;
  const b = file?.body;
  if (!b || b.format !== FORMAT || b.version !== 1 || !b.tables || (b.owner !== null && typeof b.owner !== 'string')) throw new Error('対応していない移行ファイルです');
  if (file.sha256 !== await sha256Hex(canonicalJson(b))) throw new Error('移行ファイルの内容が壊れています');
  for (const [name, rows] of Object.entries(b.tables)) {
    if (!Array.isArray(rows) || rows.some((r) => !r || typeof r !== 'object' || Array.isArray(r))) throw new Error(`${name} の形式が不正です`);
  }
  for (const entity of ENTITY_NAMES) {
    const rows = b.tables[DATA_TABLES[entity]];
    if (!rows) throw new Error(`${entity} がありません`);
    const ids = new Set<string>();
    for (let i = 0; i < rows.length; i++) {
      const raw = rows[i]!;
      const norm = normalizers[entity as keyof typeof normalizers];
      const parsed = ENTITY_SCHEMAS[entity].safeParse(norm ? norm(raw as never) : raw);
      if (!parsed.success || ids.has(parsed.data.id)) throw new Error(`${entity} の内容・IDが不正です`);
      ids.add(parsed.data.id);
      rows[i] = parsed.data;
    }
  }
  const settings = b.tables.settings ?? [];
  if (settings.length > 1) throw new Error('設定が重複しています');
  for (const row of settings) {
    for (const [key, value] of Object.entries(DEFAULT_SETTINGS)) {
      if (key in row && value !== null && typeof row[key] !== typeof value) throw new Error('設定の形式が不正です');
    }
    if (row.theme && !['system', 'light', 'dark'].includes(row.theme as string)) throw new Error('外観の設定が不正です');
    if (row.textSize && !['system', 'small', 'large', 'xlarge'].includes(row.textSize as string)) throw new Error('文字サイズが不正です');
    if (row.calendarView && !['day', '2day', 'week', 'month'].includes(row.calendarView as string)) throw new Error('表示の設定が不正です');
  }
  for (const r of b.tables.operationLog ?? []) if (typeof r.id !== 'string' || typeof r.at !== 'number' || !ENTITY_NAMES.includes(r.entity as never) || typeof r.entityId !== 'string' || typeof r.action !== 'string') throw new Error('操作ログが不正です');
  for (const r of b.tables.recovery ?? []) if (typeof r.key !== 'string' || typeof r.at !== 'number' || !ENTITY_NAMES.includes(r.entity as never) || typeof r.id !== 'string' || typeof r.reason !== 'string' || !r.record || typeof r.record !== 'object') throw new Error('退避データが不正です');
  return file;
}

/** Add only, with account ownership checks and a single atomic transaction. Never clears source data. */
export async function importDevice(db: MyTimeDB, text: string, now = Date.now()): Promise<number> {
  const { body } = await readDevice(text);
  if (body.owner !== ownerOf(db.name)) throw new Error(body.owner ? '元と同じGoogleアカウントで取り込んでください' : 'ログアウトして「この端末」の領域へ取り込んでください');
  return db.transaction('rw', db.tables, async () => {
    let added = 0;
    for (const entity of ENTITY_NAMES) {
      const dst = table(db, DATA_TABLES[entity]);
      for (const rec of body.tables[DATA_TABLES[entity]]!) {
        const id = rec.id as string;
        const existing = await dst.get(id);
        if (existing) {
          if (canonicalJson(existing) === canonicalJson(rec)) continue;
          // Initial calendars exist on both origins. Never overwrite a customized calendar.
          const initial = entity === 'calendar' && defaultCalendars(0).find((c) => c.id === id);
          if (!initial || canonicalJson({ ...existing, createdAt: 0, updatedAt: 0 }) !== canonicalJson(initial)) throw new Error('同じIDで内容の異なるデータがあります。取り込みを中止しました（元データは残っています）');
          await dst.delete(id);
        }
        await dst.add(rec);
        await db.outbox.put({ opId: newId(), at: now, entity, entityId: id, op: 'put', synced: 0 });
        added++;
      }
    }
    // Pending deletions must travel too, but cursors/receipts never cross origins.
    for (const raw of body.tables.outbox ?? []) {
      if (raw.synced !== 0 || raw.op !== 'delete' || !ENTITY_NAMES.includes(raw.entity as never) || typeof raw.entityId !== 'string') continue;
      const entity = raw.entity as typeof ENTITY_NAMES[number];
      if (!await table(db, DATA_TABLES[entity]).get(raw.entityId)) await db.outbox.put({ opId: newId(), at: now, entity, entityId: raw.entityId, op: 'delete', synced: 0 });
    }
    for (const raw of body.tables.operationLog ?? []) {
      if (typeof raw.id !== 'string' || await db.operationLog.where('id').equals(raw.id).count()) continue;
      const { seq: _seq, ...log } = raw;
      await db.operationLog.add(log as never);
    }
    for (const raw of body.tables.recovery ?? []) if (typeof raw.key === 'string') await db.recovery.put(raw as never);
    const settings = body.tables.settings?.find((r) => r.key === 'app');
    if (settings && !(await db.settings.get('app'))?.onboarded) await db.settings.put({ ...DEFAULT_SETTINGS, ...settings, key: 'app', onboarded: true } as never);
    // A full pull is necessary even when the target has already advanced its cursor.
    const st = await db.syncState.get('sync');
    if (st) await db.syncState.put({ ...st, cursor: 0 });
    await db.operationLog.add({ id: newId(), at: now, entity: 'task', entityId: 'device-transfer', action: 'import-device', detail: { origin: body.origin, added } });
    return added;
  });
}
