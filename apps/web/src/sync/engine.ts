import type Dexie from 'dexie';
import { normalizeCalendar, normalizeEvent, normalizeTask, retryDelay } from '@my-time/domain';
import type { PullChange, SyncOp } from '@my-time/contracts';
import { db as defaultDb, type MyTimeDB, type SyncEntity, type SyncState } from '../data/db';
import { localChanges } from '../data/repo';
import { api as defaultApi, ApiError, type Api, type Me, type ServerConfig, type ServerNotice } from './api';

export type SyncPhase = 'starting' | 'unavailable' | 'notConfigured' | 'loggedOut' | 'idle' | 'syncing' | 'offline' | 'error';

export interface SyncStatus {
  phase: SyncPhase;
  pending: number;
  lastSuccessAt: number | null;
  lastError: string | null;
  nextRetryAt: number | null;
  me: Me | null;
  config: ServerConfig | null;
  notices: ServerNotice[];
}

const TABLE: Record<SyncEntity, keyof MyTimeDB> = {
  calendar: 'calendars',
  event: 'events',
  task: 'tasks',
  subtask: 'subtasks',
  subject: 'subjects',
  employer: 'employers',
};

const NORMALIZE: Partial<Record<SyncEntity, (r: never) => unknown>> = {
  task: normalizeTask as (r: never) => unknown,
  event: normalizeEvent as (r: never) => unknown,
  calendar: normalizeCalendar as (r: never) => unknown,
};

const FAIL_NOTICE = 'sync:failing';

/**
 * 端末の未同期キュー（IndexedDB）とクラウドを同期する。
 * - オフラインでも書き込みはすべて端末に保存され、復帰後に冪等ID付きで送る
 * - 失敗は指数バックオフ＋ジッターで自動再試行し、続くときは「お知らせ」に1件だけ出す
 * - 未同期の変更がある記録は、サーバーからの削除・上書きで消さない
 */
export class SyncEngine {
  private status: SyncStatus = { phase: 'starting', pending: 0, lastSuccessAt: null, lastError: null, nextRetryAt: null, me: null, config: null, notices: [] };
  private listeners = new Set<(s: SyncStatus) => void>();
  private timer: ReturnType<typeof setTimeout> | undefined;
  private running = false;
  private again = false;
  private stopped = false;

  constructor(
    private database: MyTimeDB = defaultDb,
    private apiImpl: Api = defaultApi,
    private clock: () => number = Date.now,
    private rand: () => number = Math.random,
  ) {}

  subscribe(fn: (s: SyncStatus) => void): () => void {
    this.listeners.add(fn);
    fn(this.status);
    return () => this.listeners.delete(fn);
  }

  get snapshot(): SyncStatus {
    return this.status;
  }

  private set(patch: Partial<SyncStatus>) {
    this.status = { ...this.status, ...patch };
    for (const l of this.listeners) l(this.status);
  }

  private async state(): Promise<SyncState> {
    return (await this.database.syncState.get('sync')) ?? { key: 'sync', cursor: 0, lastSuccessAt: null, lastAttemptAt: null, lastError: null, attempts: 0 };
  }

  private async refreshPending() {
    this.set({ pending: await this.database.outbox.where('synced').equals(0).count() });
  }

  /** アプリ起動時：サーバーとログイン状態を確認して同期を始める */
  async start(): Promise<void> {
    this.stopped = false;
    const st = await this.state();
    this.set({ lastSuccessAt: st.lastSuccessAt, lastError: st.lastError });
    await this.refreshPending();
    if (typeof window !== 'undefined') {
      window.addEventListener('online', this.onOnline);
      document.addEventListener('visibilitychange', this.onVisible);
    }
    localChanges.addEventListener('change', this.onLocalChange);
    await this.checkAccount();
  }

  stop(): void {
    this.stopped = true;
    clearTimeout(this.timer);
    if (typeof window !== 'undefined') {
      window.removeEventListener('online', this.onOnline);
      document.removeEventListener('visibilitychange', this.onVisible);
    }
    localChanges.removeEventListener('change', this.onLocalChange);
  }

  private onOnline = () => void this.syncNow();
  private onVisible = () => {
    if (document.visibilityState === 'visible') void this.syncNow();
  };
  private onLocalChange = () => {
    void this.refreshPending();
    if (this.status.phase === 'idle' || this.status.phase === 'error' || this.status.phase === 'offline') this.schedule(1500);
  };

  async checkAccount(): Promise<void> {
    try {
      const config = await this.apiImpl.config();
      this.set({ config });
      if (!config.googleConfigured) return this.set({ phase: 'notConfigured' });
      try {
        const me = await this.apiImpl.me();
        this.set({ me });
      } catch (e) {
        if (e instanceof ApiError && e.status === 401) return this.set({ phase: 'loggedOut', me: null });
        throw e;
      }
      await this.syncNow();
    } catch (e) {
      if (e instanceof ApiError && (e.status === 404 || e.status === 405)) return this.set({ phase: 'unavailable' });
      if (e instanceof ApiError && e.status === 0) {
        this.set({ phase: 'offline' });
        return;
      }
      this.set({ phase: 'error', lastError: e instanceof Error ? e.message : String(e) });
    }
  }

  private schedule(ms: number) {
    clearTimeout(this.timer);
    if (this.stopped) return;
    this.set({ nextRetryAt: this.clock() + ms });
    this.timer = setTimeout(() => void this.syncNow(), ms);
  }

  /** 今すぐ同期（実行中なら終わったあとにもう一度） */
  async syncNow(): Promise<void> {
    if (!this.status.me) return;
    if (this.running) {
      this.again = true;
      return;
    }
    this.running = true;
    clearTimeout(this.timer);
    this.set({ phase: 'syncing', nextRetryAt: null });
    const st = await this.state();
    try {
      await this.pushAll();
      await this.pullAll();
      const now = this.clock();
      await this.database.syncState.put({ ...(await this.state()), lastSuccessAt: now, lastAttemptAt: now, lastError: null, attempts: 0 });
      await this.database.notices.where('key').equals(FAIL_NOTICE).modify({ resolvedAt: now });
      const notices = await this.apiImpl.notices().then((r) => r.items).catch(() => this.status.notices);
      this.set({ phase: 'idle', lastSuccessAt: now, lastError: null, notices });
      this.schedule(60_000); // 表示中は定期的に取り込む
    } catch (e) {
      const now = this.clock();
      if (e instanceof ApiError && e.status === 401) {
        this.set({ phase: 'loggedOut', me: null });
      } else {
        const msg = e instanceof Error ? e.message : String(e);
        const attempts = st.attempts + 1;
        await this.database.syncState.put({ ...(await this.state()), lastAttemptAt: now, lastError: msg, attempts });
        if (attempts >= 3) {
          await this.database.notices.put({ key: FAIL_NOTICE, level: 'warn', title: '同期できていません', body: `変更はこの端末に保存されています。接続が戻ると自動で送信します。（${msg}）`, createdAt: (await this.database.notices.get(FAIL_NOTICE))?.createdAt ?? now, resolvedAt: null });
        }
        const offline = e instanceof ApiError && e.status === 0;
        this.set({ phase: offline ? 'offline' : 'error', lastError: msg });
        this.schedule(retryDelay(attempts - 1, this.rand()));
      }
    } finally {
      this.running = false;
      await this.refreshPending();
      if (this.again) {
        this.again = false;
        void this.syncNow();
      }
    }
  }

  /** 未同期キューを記録ごとにまとめ、最新の状態を送る（最後の操作の opId を冪等キーに使う） */
  async pushAll(): Promise<void> {
    for (let round = 0; round < 20; round++) {
      const pending = await this.database.outbox.where('synced').equals(0).sortBy('at');
      if (!pending.length) return;
      const groups = new Map<string, { entity: SyncEntity; id: string; opIds: string[]; lastOpId: string; lastAt: number }>();
      for (const p of pending) {
        const k = `${p.entity}:${p.entityId}`;
        const g = groups.get(k) ?? { entity: p.entity, id: p.entityId, opIds: [], lastOpId: p.opId, lastAt: p.at };
        g.opIds.push(p.opId);
        g.lastOpId = p.opId;
        g.lastAt = p.at;
        groups.set(k, g);
      }
      const batch = [...groups.values()].slice(0, 200);
      const ops: SyncOp[] = [];
      for (const g of batch) {
        const table = this.database[TABLE[g.entity]] as unknown as Dexie.Table<Record<string, unknown>, string>;
        const rec = await table.get(g.id);
        const meta = await this.database.meta.get(`${g.entity}:${g.id}`);
        ops.push({ opId: g.lastOpId, entity: g.entity, entityId: g.id, op: rec ? 'put' : 'delete', record: rec ?? null, baseVersion: meta?.version ?? 0, clientUpdatedAt: (rec?.updatedAt as number | undefined) ?? g.lastAt });
      }
      const res = await this.apiImpl.push(ops);
      await this.database.transaction('rw', [this.database.outbox, this.database.meta, this.database.notices, ...Object.values(TABLE).map((t) => this.database[t] as unknown as Dexie.Table)], async () => {
        for (const [i, r] of res.results.entries()) {
          const g = batch[i]!;
          const key = `${g.entity}:${g.id}`;
          const table = this.database[TABLE[g.entity]] as unknown as Dexie.Table<Record<string, unknown>, string>;
          if (r.status === 'conflict') {
            // サーバー側の方が新しかった：サーバーの内容で端末を上書き（端末の古い変更は操作ログに残る）
            if (r.serverRecord) await table.put((NORMALIZE[g.entity]?.(r.serverRecord as never) ?? r.serverRecord) as Record<string, unknown>);
            else await table.delete(g.id);
          }
          if (r.status === 'rejected') {
            await this.database.notices.put({ key: `sync:rejected:${key}`, level: 'warn', title: '保存できなかった変更があります', body: `サーバーが受け付けなかったため、この変更はこの端末にのみ残っています（${r.reason ?? '検証エラー'}）。`, createdAt: this.clock(), resolvedAt: null });
          }
          await this.database.meta.put({ key, entity: g.entity, id: g.id, version: r.version, restoredSessionId: (await this.database.meta.get(key))?.restoredSessionId ?? null });
          await this.database.outbox.where('opId').anyOf(g.opIds).modify({ synced: 1 });
        }
      });
    }
  }

  async pullAll(): Promise<void> {
    for (let page = 0; page < 50; page++) {
      const st = await this.state();
      const res = await this.apiImpl.pull(st.cursor);
      await this.applyRemote(res.changes);
      await this.database.syncState.put({ ...(await this.state()), cursor: res.cursor });
      if (!res.hasMore) return;
    }
  }

  /** サーバーの変更を端末へ反映。未同期の変更がある記録には触れない（次の送信でサーバー側を更新する） */
  async applyRemote(changes: PullChange[]): Promise<void> {
    await this.database.transaction('rw', [this.database.outbox, this.database.meta, ...Object.values(TABLE).map((t) => this.database[t] as unknown as Dexie.Table)], async () => {
      for (const c of changes) {
        const table = this.database[TABLE[c.entity]] as unknown as Dexie.Table<Record<string, unknown>, string>;
        const key = `${c.entity}:${c.id}`;
        const dirty = await this.database.outbox.where('[entity+entityId]').equals([c.entity, c.id]).filter((o) => o.synced === 0).count();
        if (dirty > 0) continue;
        if (c.deleted || !c.record) {
          await table.delete(c.id);
          await this.database.meta.delete(key);
        } else {
          await table.put((NORMALIZE[c.entity]?.(c.record as never) ?? c.record) as Record<string, unknown>);
          await this.database.meta.put({ key, entity: c.entity, id: c.id, version: c.version, restoredSessionId: c.restoredSessionId });
        }
      }
    });
  }
}


export const syncEngine = new SyncEngine();
