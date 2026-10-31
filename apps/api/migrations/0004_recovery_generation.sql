-- Existing devices must re-pull after disaster recovery, even if their old
-- cursor is beyond the backup's final cursor.
ALTER TABLE sync_seq ADD COLUMN generation TEXT NOT NULL DEFAULT 'initial';
