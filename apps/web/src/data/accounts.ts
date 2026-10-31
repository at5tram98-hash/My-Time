import { defaultCalendars, newId } from '@my-time/domain';
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
 * - 移行先へ書き終えてから元の領域を空にする（途中で止まっても二重にはならない：同じIDは飛ばす）
 */
export async function migrateLocalToAccount(local: MyTimeDB, target: MyTimeDB, now: number): Promise<number> {
  let moved = 0;
  const entities = Object.keys(DATA_TABLES) as SyncEntity[];
  const tables = entities.map((e) => target[DATA_TABLES[e]]);
  // 元の領域を先に読み切る（別の DB をトランザクションの中で読むと、そのトランザクションが終わってしまう）
  const source = new Map<SyncEntity, { id: string }[]>();
  for (const entity of entities) source.set(entity, (await local[DATA_TABLES[entity]].toArray()) as unknown as { id: string }[]);
  await target.transaction('rw', [...tables, target.outbox, target.operationLog], async () => {
    for (const entity of entities) {
      const src = source.get(entity)!;
      const dst = target[DATA_TABLES[entity]] as unknown as { get(id: string): Promise<unknown>; put(r: unknown): Promise<unknown> };
      for (const rec of src) {
        if (await dst.get(rec.id)) continue;
        await dst.put(rec);
        await target.outbox.put({ opId: newId(), at: now, entity, entityId: rec.id, op: 'put', synced: 0 });
        await target.operationLog.add({ id: newId(), at: now, entity, entityId: rec.id, action: 'migrate', detail: { from: 'この端末（ログインなし）' } });
        moved += 1;
      }
    }
  });
  await local.transaction('rw', [...entities.map((e) => local[DATA_TABLES[e]]), local.outbox, local.meta], async () => {
    for (const entity of entities) await local[DATA_TABLES[entity]].clear();
    await local.outbox.clear();
    await local.meta.clear();
  });
  return moved;
}
