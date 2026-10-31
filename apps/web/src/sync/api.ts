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
}

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
  let res: Response;
  try {
    res = await fetch(`${import.meta.env.BASE_URL}api${path}`, {
      ...init,
      credentials: 'same-origin',
      headers: { 'x-mytime': '1', ...(init.body ? { 'content-type': 'application/json' } : {}), ...(init.headers ?? {}) },
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
  push: (ops: SyncOp[]) => call<PushResult>('/sync/push', { method: 'POST', body: JSON.stringify({ ops }) }),
  pull: (cursor: number) => call<PullResult>(`/sync/pull?cursor=${cursor}`),
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
