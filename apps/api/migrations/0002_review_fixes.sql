-- Phase 2 レビュー対応（追加のみ。既存データは削除・変更しない）

-- OAuth の state をログインを始めたブラウザに結び付ける（ログイン CSRF 対策）。
-- ブラウザには HttpOnly Cookie で乱数を渡し、ここにはそのハッシュだけを保存する。
ALTER TABLE oauth_states ADD COLUMN browser_hash TEXT NOT NULL DEFAULT '';

-- 日次バックアップに含める操作ログの範囲を素早く取り出すため
CREATE INDEX IF NOT EXISTS operation_log_user_seq ON operation_log(user_id, seq);
