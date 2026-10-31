import type Dexie from 'dexie';
import { canonicalJson, normalizeCalendar, normalizeEvent, normalizeTask, retryDelay } from '@my-time/domain';
import type { PullChange, SyncOp } from '@my-time/contracts';
import { accountDbName, db as defaultDb, LOCAL_DB, MyTimeDB, ownerOf, switchActiveDb, type SyncEntity, type SyncState } from '../data/db';
import { localSummary, migrateLocalToAccount, prepareAccountDb, summaryText, type LocalSummary } from '../data/accounts';
import { localChanges } from '../data/repo';
import { api as defaultApi, ApiError, type Api, type Me, type ServerConfig, type ServerNotice } from './api';

export type SyncPhase = 'starting' | 'unavailable' | 'notConfigured' | 'loggedOut' | 'idle' | 'syncing' | 'offline' | 'error' | 'chooseAccount' | 'switching';

export interface SyncStatus {
  phase: SyncPhase;
  pending: number;
  lastSuccessAt: number | null;
  lastError: string | null;
  nextRetryAt: number | null;
  me: Me | null;
  config: ServerConfig | null;
  notices: ServerNotice[];
  /** ログインしていない間のデータがある状態でログインした：移すかどうか本人に確認する */
  pendingMigration: { me: Me; summary: LocalSummary } | null;
}

/** 保存領域の切り替え（本番は再読み込み。テストでは差し替える） */
export interface AccountHooks {
  switchTo: (dbName: string, flash?: string) => void;
  open: (dbName: string) => MyTimeDB;
}
const defaultHooks: AccountHooks = { switchTo: switchActiveDb, open: (name) => new MyTimeDB(name) };

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
  private status: SyncStatus = { phase: 'starting', pending: 0, lastSuccessAt: null, lastError: null, nextRetryAt: null, me: null, config: null, notices: [], pendingMigration: null };
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
    private hooks: AccountHooks = defaultHooks,
  ) {}

  /** この保存領域の持ち主（ログインしていない間の領域なら null） */
  get owner(): string | null {
    return ownerOf(this.database.name);
  }

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

  /**
   * ログイン状態と、表示中の保存領域の持ち主を突き合わせる。
   * - 同じアカウント … 同期する
   * - 別のアカウントの領域 … 何も送らず、ログイン中のアカウントの領域へ切り替える（前のアカウントの未送信は端末に残る）
   * - ログインしていない間の領域 … データがなければそのまま切り替え、あれば移すかどうか本人に確認する
   */
  async checkAccount(): Promise<void> {
    try {
      const config = await this.apiImpl.config();
      this.set({ config });
      if (!config.googleConfigured) return this.set({ phase: 'notConfigured' });
      let me: Me;
      try {
        me = await this.apiImpl.me();
      } catch (e) {
        if (e instanceof ApiError && e.status === 401) return this.set({ phase: 'loggedOut', me: null });
        throw e;
      }
      const owner = this.owner;
      if (owner === me.user.id) {
        this.set({ me, pendingMigration: null });
        await this.syncNow();
        return;
      }
      clearTimeout(this.timer);
      if (owner) {
        const unsent = await this.database.outbox.where('synced').equals(0).count();
        await this.switchToAccount(me, unsent ? `アカウントを切り替えました。前のアカウントの未送信の変更${unsent}件はこの端末に保存されています（そのアカウントでログインし直すと送信します）。` : `${me.user.email} に切り替えました`);
        return;
      }
      const summary = await localSummary(this.database);
      if (summary.total === 0) {
        await this.switchToAccount(me, `${me.user.email} でログインしました`);
        return;
      }
      this.set({ phase: 'chooseAccount', me, pendingMigration: { me, summary } });
    } catch (e) {
      if (e instanceof ApiError && (e.status === 404 || e.status === 405)) return this.set({ phase: 'unavailable' });
      if (e instanceof ApiError && e.status === 0) {
        this.set({ phase: 'offline' });
        return;
      }
      this.set({ phase: 'error', lastError: e instanceof Error ? e.message : String(e) });
    }
  }

  private async switchToAccount(me: Me, flash: string, migrate = false): Promise<number> {
    this.set({ phase: 'switching' });
    const target = this.hooks.open(accountDbName(me.user.id));
    await prepareAccountDb(this.database, target);
    const moved = migrate ? await migrateLocalToAccount(this.database, target, this.clock()) : 0;
    this.stop();
    this.hooks.switchTo(accountDbName(me.user.id), flash);
    return moved;
  }

  /** ログインしていない間のデータを移すか（本人の選択） */
  async resolveMigration(migrate: boolean): Promise<number> {
    const p = this.status.pendingMigration;
    if (!p) return 0;
    if (!migrate) return this.switchToAccount(p.me, `この端末のデータ（${summaryText(p.summary)}）は移さずに残しました。ログアウトすると表示されます。`);
    return this.switchToAccount(p.me, `${summaryText(p.summary)}を ${p.me.user.email} に移しました。同期を始めます。`, true);
  }

  /** ログアウト：ログインしていない間の領域に戻る。アカウントのデータ（未送信を含む）は端末に残す */
  async logout(): Promise<void> {
    await this.apiImpl.logout().catch(() => undefined);
    const unsent = await this.database.outbox.where('synced').equals(0).count();
    this.stop();
    this.set({ me: null, phase: 'loggedOut' });
    if (this.database.name !== LOCAL_DB) {
      this.hooks.switchTo(LOCAL_DB, unsent ? `ログアウトしました。未送信の変更${unsent}件はこの端末に保存され、同じアカウントでログインすると送信します。` : 'ログアウトしました');
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
    // 送受信するのは「ログイン中のアカウントの保存領域」を表示しているときだけ
    const account = this.owner;
    if (!this.status.me || !account || this.status.me.user.id !== account) return;
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
      await this.syncSettings();
      const now = this.clock();
      await this.database.syncState.put({ ...(await this.state()), lastSuccessAt: now, lastAttemptAt: now, lastError: null, attempts: 0 });
      await this.database.notices.where('key').equals(FAIL_NOTICE).modify({ resolvedAt: now });
      const notices = await this.apiImpl.notices().then((r) => r.items).catch(() => this.status.notices);
      this.set({ phase: 'idle', lastSuccessAt: now, lastError: null, notices });
      this.schedule(60_000); // 表示中は定期的に取り込む
    } catch (e) {
      const now = this.clock();
      if (e instanceof ApiError && e.status === 401) {
        // セッション切れ：この領域のまま（未送信は残る）。同じアカウントでログインし直せば続きから送る
        this.set({ phase: 'loggedOut', me: null });
      } else if (e instanceof ApiError && e.status === 409) {
        // 別のタブなどで別アカウントにログインした：送らずに確認し直す
        this.running = false;
        await this.checkAccount();
        return;
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
      const res = await this.apiImpl.push(ops, this.owner!);
      const resultById = new Map(res.results.map((r) => [r.opId, r]));
      if (resultById.size !== ops.length || ops.some((o) => !resultById.has(o.opId))) throw new Error('同期の受領確認が不完全です。再送します');
      // すべて「再送」なら今回はここまで（サーバーの同時処理が落ち着いてから、バックオフで再試行）
      if (res.results.every((r) => r.status === 'retry')) throw new Error('サーバーで同時に更新中のため、少し待ってから再送します');
      await this.database.transaction('rw', [this.database.outbox, this.database.meta, this.database.notices, this.database.recovery, ...Object.values(TABLE).map((t) => this.database[t] as unknown as Dexie.Table)], async () => {
        for (const [i, g] of batch.entries()) {
          const r = resultById.get(g.lastOpId)!;
          const key = `${g.entity}:${g.id}`;
          const table = this.database[TABLE[g.entity]] as unknown as Dexie.Table<Record<string, unknown>, string>;
          // 同時更新で書けなかった：端末の変更はそのまま残し、次回の同期で送り直す
          if (r.status === 'retry') continue;
          const local = await table.get(g.id);
          const newer = await this.database.outbox.where('[entity+entityId]').equals([g.entity, g.id]).filter((o) => o.synced === 0 && !g.opIds.includes(o.opId)).count();
          if (r.status === 'conflict' || r.status === 'rejected') {
            if (local) await this.database.recovery.put({ key: `${key}:${g.lastOpId}`, entity: g.entity, id: g.id, at: this.clock(), reason: r.serverDeleted ? `tombstone:${r.deleteReason}` : r.status, record: local });
          }
          if (r.status === 'conflict' && r.serverDeleted) {
            // サーバーで削除済み（ユーザー削除・期限削除・復元閲覧の終了）。削除が常に優先され、端末の記録も消す
            const hadEdit = ops[i]!.op === 'put';
            await table.delete(g.id);
            await this.database.meta.put({ key, entity: g.entity, id: g.id, version: r.version, restoredSessionId: null });
            if (hadEdit) {
              await this.database.notices.put({
                key: `sync:tombstone:${key}`,
                level: 'warn',
                title: '削除済みのデータへの変更は反映されませんでした',
                body:
                  r.deleteReason === 'purge'
                    ? '保存期間（30日）を過ぎてバックアップ済みのデータを、この端末で変更していました。変更内容はこの端末の退避データに保存され、移行ファイルに書き出せます。必要なら「期間指定の復元」から戻せます。'
                    : '別の端末などで削除されたデータを、この端末で変更していました。変更内容はこの端末の退避データに保存され、移行ファイルに書き出せます。',
                createdAt: this.clock(),
                resolvedAt: null,
              });
            }
            await this.database.outbox.where('[entity+entityId]').equals([g.entity, g.id]).modify({ synced: 1 });
            continue;
          }
          if (r.status === 'conflict' && !newer) {
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

  /**
   * アプリ設定の同期（日次バックアップに含め、別の端末・復元でも同じ使い心地にする）。
   * この端末で初めて同期するときはサーバーの設定を取り込み、その後は変更があったときだけ送る。
   */
  async syncSettings(): Promise<void> {
    const account = this.owner!;
    const st = await this.state();
    const local = await this.database.settings.get('app');
    if (st.settingsJson == null) {
      const server = await this.apiImpl.getSettings(account).catch(() => ({}) as Record<string, unknown>);
      if (Object.keys(server).length) {
        const merged = { ...(local ?? {}), ...(server as object), key: 'app', onboarded: true };
        await this.database.settings.put(merged as never);
        const { key: _key, ...rest } = merged;
        await this.database.syncState.put({ ...(await this.state()), settingsJson: canonicalJson(rest) });
        if (canonicalJson(rest) === canonicalJson(server)) return;
      }
    }
    const { key: _k, ...cur } = (await this.database.settings.get('app')) ?? { key: 'app' };
    const json = canonicalJson(cur);
    if (json === st.settingsJson) return;
    await this.apiImpl.putSettings(cur as Record<string, unknown>, account);
    await this.database.syncState.put({ ...(await this.state()), settingsJson: json });
  }

  async pullAll(): Promise<void> {
    for (let page = 0; page < 50; page++) {
      const st = await this.state();
      const res = await this.apiImpl.pull(st.cursor, this.owner!);
      if (!Number.isSafeInteger(res.cursor) || res.cursor < st.cursor || (res.hasMore && res.cursor === st.cursor)) throw new Error('同期カーソルが不正です');
      await this.applyRemote(res.changes, res.cursor);
      if (!res.hasMore) return;
    }
  }

  /** サーバーの変更を端末へ反映。未同期の変更がある記録には触れない（次の送信でサーバー側を更新する） */
  async applyRemote(changes: PullChange[], cursor?: number): Promise<void> {
    await this.database.transaction('rw', [this.database.outbox, this.database.meta, this.database.syncState, this.database.recovery, this.database.notices, ...Object.values(TABLE).map((t) => this.database[t] as unknown as Dexie.Table)], async () => {
      for (const c of changes) {
        const table = this.database[TABLE[c.entity]] as unknown as Dexie.Table<Record<string, unknown>, string>;
        const key = `${c.entity}:${c.id}`;
        const dirty = await this.database.outbox.where('[entity+entityId]').equals([c.entity, c.id]).filter((o) => o.synced === 0).count();
        const meta = await this.database.meta.get(key);
        if (meta && c.version < meta.version) continue;
        if (dirty > 0 && !c.deleted) continue;
        if (dirty > 0 && c.deleted) {
          const local = await table.get(c.id);
          if (local) await this.database.recovery.put({ key: `${key}:pull:${c.version}`, entity: c.entity, id: c.id, at: this.clock(), reason: `tombstone:${c.reason}`, record: local });
          await this.database.outbox.where('[entity+entityId]').equals([c.entity, c.id]).modify({ synced: 1 });
          await this.database.notices.put({ key: `sync:tombstone:${key}`, level: 'warn', title: '削除済みのデータへの変更を退避しました', body: '変更内容を移行ファイルに書き出せます。削除済みデータは自動で復活させません。', createdAt: this.clock(), resolvedAt: null });
        }
        if (c.deleted || !c.record) {
          await table.delete(c.id);
          await this.database.meta.put({ key, entity: c.entity, id: c.id, version: c.version, restoredSessionId: null });
        } else {
          await table.put((NORMALIZE[c.entity]?.(c.record as never) ?? c.record) as Record<string, unknown>);
          await this.database.meta.put({ key, entity: c.entity, id: c.id, version: c.version, restoredSessionId: c.restoredSessionId });
        }
      }
      if (cursor !== undefined) await this.database.syncState.put({ ...(await this.state()), cursor });
    });
  }
}


export const syncEngine = new SyncEngine();
