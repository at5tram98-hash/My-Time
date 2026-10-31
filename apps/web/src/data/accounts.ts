import { canonicalJson, defaultCalendars, newId } from '@my-time/domain';
import { DEFAULT_SETTINGS, type MyTimeDB, type SyncEntity } from './db';

/** 同期するデータの表（エンティティ → IndexedDB の表名） */
export const DATA_TABLES = {
  calendar: 'calendars',
  event: 'events',
  task: 'tasks',
  subtask: 'subtasks',
  subject: 'subjects',
  employer: 'employers',
} as const satisfies Record<SyncEntity, keyof MyTimeDB>;

export interface LocalSummary {
  tasks: number;
  events: number;
  subtasks: number;
  subjects: number;
  employers: number;
  /** 初期の3つ（一般・授業・アルバイト）から変更・追加したカレンダー */
  calendars: number;
  total: number;
}

const DEFAULT_CAL = new Set(defaultCalendars(0).map((c) => c.id));

/** ログインしていない間に作ったデータの件数（初期カレンダーをそのまま使っているだけなら数えない） */
export async function localSummary(db: MyTimeDB): Promise<LocalSummary> {
  const [tasks, events, subtasks, subjects, employers] = await Promise.all([db.tasks.count(), db.events.count(), db.subtasks.count(), db.subjects.count(), db.employers.count()]);
  const calendars = (await db.calendars.toArray()).filter((c) => !DEFAULT_CAL.has(c.id) || c.updatedAt !== c.createdAt).length;
  return { tasks, events, subtasks, subjects, employers, calendars, total: tasks + events + subtasks + subjects + employers + calendars };
}

export function summaryText(s: LocalSummary): string {
  const parts = [
    s.tasks && `タスク${s.tasks}件`,
    s.events && `予定${s.events}件`,
    s.subtasks && `サブタスク${s.subtasks}件`,
    s.calendars && `カレンダー${s.calendars}件`,
    s.subjects && `科目${s.subjects}件`,
    s.employers && `勤務先${s.employers}件`,
  ].filter(Boolean);
  return parts.join('・') || 'なし';
}

/**
 * 新しいアカウントの保存領域を使い始める準備：外観などの設定を引き継ぎ、初回セットアップは出さない。
 * すでに設定がある領域（以前ログインしたアカウント）はそのまま。
 */
export async function prepareAccountDb(from: MyTimeDB, target: MyTimeDB): Promise<void> {
  if (await target.settings.get('app')) return;
  const cur = await from.settings.get('app');
  await target.settings.put({ ...DEFAULT_SETTINGS, ...cur, key: 'app', onboarded: true });
}

/**
 * ログインしていない間のデータを、本人が確認したうえでアカウントの保存領域へ移す。
 * - 移した記録は「新規作成」として未同期キューに入り、次の同期で送られる
 * - 移行先に同じIDの記録がすでにあれば、移行先を優先して上書きしない（初期カレンダーなど）
 * - 元の領域は復旧用に残す。同じIDの異なる内容は、初期カレンダー以外は取り込み全体を中止する。
 */
export async function migrateLocalToAccount(local: MyTimeDB, target: MyTimeDB, now: number): Promise<number> {
  let moved = 0;
  const entities = Object.keys(DATA_TABLES) as SyncEntity[];
  const tables = entities.map((e) => target[DATA_TABLES[e]]);
  // 元の領域を先に読み切る（別の DB をトランザクションの中で読むと、そのトランザクションが終わってしまう）
  const source = new Map<SyncEntity, { id: string }[]>();
  await local.transaction('r', entities.map((e) => local[DATA_TABLES[e]]), async () => {
    for (const entity of entities) source.set(entity, (await local[DATA_TABLES[entity]].toArray()) as unknown as { id: string }[]);
  });
  const logs = await local.operationLog.toArray();
  await target.transaction('rw', [...tables, target.outbox, target.operationLog], async () => {
    for (const entity of entities) {
      const src = source.get(entity)!;
      const dst = target[DATA_TABLES[entity]] as unknown as { get(id: string): Promise<unknown>; put(r: unknown): Promise<unknown> };
      for (const rec of src) {
        const existing = await dst.get(rec.id);
        if (existing) {
          if (canonicalJson(existing) === canonicalJson(rec)) continue;
          if (entity === 'calendar' && DEFAULT_CAL.has(rec.id)) {
            const initial = defaultCalendars(0).find((c) => c.id === rec.id)!;
            if (canonicalJson({ ...(existing as object), createdAt: 0, updatedAt: 0 }) === canonicalJson(initial)) {
              // A fresh account can adopt the local calendar customization.
            } else throw new Error('同じIDで異なるカレンダーがあります。元データは端末に残しています');
          } else throw new Error('同じIDで異なるデータがあります。元データは端末に残しています');
        }
        await dst.put(rec);
        await target.outbox.put({ opId: newId(), at: now, entity, entityId: rec.id, op: 'put', synced: 0 });
        await target.operationLog.add({ id: newId(), at: now, entity, entityId: rec.id, action: 'migrate', detail: { from: 'この端末（ログインなし）' } });
        moved += 1;
      }
    }
    for (const log of logs) {
      if (await target.operationLog.where('id').equals(log.id).count()) continue;
      const { seq: _seq, ...entry } = log;
      await target.operationLog.add(entry);
    }
  });
  return moved;
}
