import { db, ownerOf } from '../data/db';
import type { PullResult, PushResult, SyncOp } from '@my-time/contracts';

/** API がない配信先（例：GitHub Pages の旧版）では 'unavailable' を返し、機能を「未設定」と表示する */
export class ApiError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

export interface ServerConfig {
  googleConfigured: boolean;
  pushPublicKey: string | null;
  apiVersion: number;
  /** 期限削除（30日）の動作：off＝停止／dry-run＝試運転／on＝実行 */
  retentionMode?: 'off' | 'dry-run' | 'on';
}

export interface RestoreDrill {
  ok: boolean;
  matched: number;
  missingNow: string[];
  extraNow: string[];
  changed: string[];
  kind: 'daily' | 'archive';
  extras: { settings: number; operationLog: number; tombstones: number };
}

/** 送受信のときに付ける「どのアカウントの保存領域か」。サーバーはログイン中のアカウントと違えば拒否する */
const acct = (account: string) => ({ 'x-mytime-account': account });

export interface Me {
  user: { id: string; email: string; name: string };
  drive: { connected: boolean };
}

export interface ServerNotice {
  id: string;
  level: 'info' | 'warn' | 'error';
  kind: string;
  title: string;
  body: string;
  created_at: number;
  read_at: number | null;
  resolved_at: number | null;
}

export interface BackupItem {
  id: string;
  kind: 'daily' | 'archive';
  created_at: number;
  drive_file_name: string | null;
  bytes: number | null;
  counts: string | null;
  status: 'uploading' | 'verified' | 'failed' | 'deleted';
  verified_at: number | null;
  error: string | null;
  range_from: number | null;
  range_to: number | null;
}

export interface RestoreSession {
  id: string;
  range_from: number;
  range_to: number;
  created_at: number;
  restored_count: number;
}

async function call<T>(path: string, init: RequestInit = {}): Promise<T> {
  const account = ownerOf(db.name);
  const scoped = !['/config', '/me', '/auth/logout'].includes(path);
  if (scoped && !account) throw new ApiError('アカウントの保存領域に切り替えてから操作してください', 409);
  let res: Response;
  try {
    res = await fetch(`${import.meta.env.BASE_URL}api${path}`, {
      ...init,
      credentials: 'same-origin',
      headers: { 'x-mytime': '1', ...(scoped && account ? acct(account) : {}), ...(init.body ? { 'content-type': 'application/json' } : {}), ...(init.headers ?? {}) },
    });
  } catch {
    throw new ApiError('オフラインです', 0);
  }
  const type = res.headers.get('content-type') ?? '';
  if (!type.includes('application/json')) throw new ApiError('サーバーがありません', res.status === 200 ? 404 : res.status);
  const body = (await res.json()) as T & { error?: string };
  if (!res.ok) throw new ApiError(body.error ?? `エラー（${res.status}）`, res.status);
  return body;
}

export const api = {
  config: () => call<ServerConfig>('/config'),
  me: () => call<Me>('/me'),
  logout: () => call<{ ok: boolean }>('/auth/logout', { method: 'POST' }),
  push: (ops: SyncOp[], account: string) => call<PushResult>('/sync/push', { method: 'POST', body: JSON.stringify({ ops }), headers: acct(account) }),
  pull: (cursor: number, account: string) => call<PullResult>(`/sync/pull?cursor=${cursor}`, { headers: acct(account) }),
  getSettings: (account: string) => call<Record<string, unknown>>('/settings', { headers: acct(account) }),
  putSettings: (data: Record<string, unknown>, account: string) => call<{ ok: boolean }>('/settings', { method: 'PUT', body: JSON.stringify(data), headers: acct(account) }),
  restoreDrill: (id: string) => call<RestoreDrill>(`/backups/${id}/drill`, { method: 'POST' }),
  notices: () => call<{ items: ServerNotice[] }>('/notifications'),
  readNotice: (id: string) => call(`/notifications/${id}/read`, { method: 'POST' }),
  backups: () => call<{ items: BackupItem[]; activeRestorations: number }>('/backups'),
  runBackup: () => call<{ ok: boolean; error?: string }>('/backups/run', { method: 'POST' }),
  deleteBackup: (id: string) => call(`/backups/${id}`, { method: 'DELETE' }),
  restore: (from: number, to: number) => call<{ sessionId: string; restored: number }>('/restore', { method: 'POST', body: JSON.stringify({ from, to }) }),
  restoreSessions: () => call<{ items: RestoreSession[] }>('/restore'),
  endRestore: (id: string) => call<{ removed: number }>(`/restore/${id}/end`, { method: 'POST' }),
  subscribePush: (sub: PushSubscriptionJSON) => call('/push/subscribe', { method: 'POST', body: JSON.stringify(sub) }),
  unsubscribePush: (endpoint: string) => call('/push/unsubscribe', { method: 'POST', body: JSON.stringify({ endpoint }) }),
  loginUrl: () => `${import.meta.env.BASE_URL}api/auth/login`,
};

export type Api = typeof api;
