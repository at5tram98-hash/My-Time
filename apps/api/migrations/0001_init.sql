-- My Time Phase 2 初期スキーマ（D1 / SQLite）
-- 同期対象のレコードは entity 列で区別する汎用テーブル（records）に保存する。
-- 理由：クライアントの IndexedDB と1対1で対応し、版数・削除理由・復元セッションを全エンティティで同じ規則で扱えるため（docs/adr/0002-sync-store.md）。


CREATE TABLE users (
  id TEXT PRIMARY KEY,
  google_sub TEXT NOT NULL UNIQUE,
  email TEXT NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE sessions (
  id TEXT PRIMARY KEY,            -- セッショントークンの SHA-256（生のトークンは保存しない）
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  user_agent TEXT NOT NULL DEFAULT ''
);
CREATE INDEX sessions_user ON sessions(user_id);

CREATE TABLE oauth_states (
  state TEXT PRIMARY KEY,
  code_verifier TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE oauth_grants (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  refresh_token_enc TEXT NOT NULL,  -- AES-GCM で暗号化（鍵は Workers のシークレット）
  scope TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  revoked_at INTEGER
);

CREATE TABLE sync_seq (
  user_id TEXT PRIMARY KEY,
  seq INTEGER NOT NULL
);

CREATE TABLE records (
  user_id TEXT NOT NULL,
  entity TEXT NOT NULL,
  id TEXT NOT NULL,
  version INTEGER NOT NULL,
  data TEXT,                       -- JSON。削除済みは NULL
  deleted INTEGER NOT NULL DEFAULT 0,
  delete_reason TEXT,              -- user / purge / restore-end
  updated_at INTEGER NOT NULL,     -- レコード側の updatedAt（衝突解決に使う）
  server_seq INTEGER NOT NULL,     -- pull のカーソル
  restored_session_id TEXT,        -- 期間指定復元で一時的に戻したもの
  PRIMARY KEY (user_id, entity, id)
);
CREATE INDEX records_seq ON records(user_id, server_seq);

CREATE TABLE sync_receipts (
  user_id TEXT NOT NULL,
  op_id TEXT NOT NULL,             -- クライアントの冪等ID
  status TEXT NOT NULL,
  version INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, op_id)
);

CREATE TABLE operation_log (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  at INTEGER NOT NULL,
  entity TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  action TEXT NOT NULL,
  detail TEXT
);
CREATE INDEX operation_log_user ON operation_log(user_id, at);

CREATE TABLE backup_manifests (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  kind TEXT NOT NULL,              -- daily / archive
  created_at INTEGER NOT NULL,
  drive_file_id TEXT,
  drive_file_name TEXT,
  sha256 TEXT,
  bytes INTEGER,
  counts TEXT,
  schema_version INTEGER,
  range_from INTEGER,
  range_to INTEGER,
  status TEXT NOT NULL,            -- uploading / verified / failed / deleted
  verified_at INTEGER,
  error TEXT
);
CREATE INDEX backup_manifests_user ON backup_manifests(user_id, kind, created_at);

CREATE TABLE archive_entries (
  user_id TEXT NOT NULL,
  entity TEXT NOT NULL,
  id TEXT NOT NULL,                -- 繰り返しの各回は "<マスター>@<開始>"
  version INTEGER NOT NULL,
  manifest_id TEXT NOT NULL REFERENCES backup_manifests(id),
  range_at INTEGER,                -- 期間指定復元の検索用（予定の開始・タスクの予定開始など）
  archived_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, entity, id, version)
);
CREATE INDEX archive_entries_range ON archive_entries(user_id, range_at);

CREATE TABLE purge_ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,
  entity TEXT NOT NULL,
  record_id TEXT NOT NULL,
  version INTEGER NOT NULL,
  manifest_id TEXT NOT NULL,
  reason TEXT NOT NULL,
  purged_at INTEGER NOT NULL
);

CREATE TABLE restoration_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  range_from INTEGER NOT NULL,
  range_to INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  ended_at INTEGER,
  restored_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE notifications (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  level TEXT NOT NULL,             -- info / warn / error
  kind TEXT NOT NULL,              -- sync / backup / quota / auth / purge
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  dedupe_key TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  read_at INTEGER,
  resolved_at INTEGER,
  UNIQUE (user_id, dedupe_key)
);

CREATE TABLE push_subscriptions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  failures INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE sent_notices (
  user_id TEXT NOT NULL,
  key TEXT NOT NULL,
  sent_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, key)
);

CREATE TABLE user_settings (
  user_id TEXT PRIMARY KEY,
  data TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
