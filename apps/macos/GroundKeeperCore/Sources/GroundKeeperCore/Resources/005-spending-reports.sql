-- Analytics revisions cover every table that changes report membership, amounts or certainty.
CREATE TABLE analytics_revision (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL) STRICT;
INSERT INTO analytics_revision VALUES (1, 0);
CREATE TRIGGER analytics_transactions_insert AFTER INSERT ON transactions BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_transactions_update AFTER UPDATE ON transactions BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_transactions_delete AFTER DELETE ON transactions BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_transaction_parts_insert AFTER INSERT ON transaction_parts BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_transaction_parts_update AFTER UPDATE ON transaction_parts BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_transaction_parts_delete AFTER DELETE ON transaction_parts BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_category_assignments_insert AFTER INSERT ON category_assignments BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_category_assignments_update AFTER UPDATE ON category_assignments BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_category_assignments_delete AFTER DELETE ON category_assignments BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_review_items_insert AFTER INSERT ON review_items BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_review_items_update AFTER UPDATE ON review_items BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_review_items_delete AFTER DELETE ON review_items BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_transaction_event_links_insert AFTER INSERT ON transaction_event_links BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_transaction_event_links_update AFTER UPDATE ON transaction_event_links BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_transaction_event_links_delete AFTER DELETE ON transaction_event_links BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_transaction_tags_insert AFTER INSERT ON transaction_tags BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_transaction_tags_update AFTER UPDATE ON transaction_tags BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_transaction_tags_delete AFTER DELETE ON transaction_tags BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_part_tags_insert AFTER INSERT ON part_tags BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_part_tags_update AFTER UPDATE ON part_tags BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_part_tags_delete AFTER DELETE ON part_tags BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_tags_insert AFTER INSERT ON tags BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_tags_update AFTER UPDATE ON tags BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_tags_delete AFTER DELETE ON tags BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
