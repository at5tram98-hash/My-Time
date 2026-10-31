-- Allocate the visible cursor in the same transaction as each record write.
-- Reserving a sequence before a write can otherwise publish N+1 before N.
CREATE TRIGGER records_insert_cursor AFTER INSERT ON records BEGIN
  INSERT INTO sync_seq(user_id, seq) VALUES (NEW.user_id, 1)
    ON CONFLICT(user_id) DO UPDATE SET seq = seq + 1;
  UPDATE records SET server_seq = (SELECT seq FROM sync_seq WHERE user_id = NEW.user_id)
    WHERE user_id = NEW.user_id AND entity = NEW.entity AND id = NEW.id;
END;
CREATE TRIGGER records_update_cursor AFTER UPDATE OF version, data, deleted ON records BEGIN
  INSERT INTO sync_seq(user_id, seq) VALUES (NEW.user_id, 1)
    ON CONFLICT(user_id) DO UPDATE SET seq = seq + 1;
  UPDATE records SET server_seq = (SELECT seq FROM sync_seq WHERE user_id = NEW.user_id)
    WHERE user_id = NEW.user_id AND entity = NEW.entity AND id = NEW.id;
END;
ALTER TABLE sync_receipts ADD COLUMN result_json TEXT;
