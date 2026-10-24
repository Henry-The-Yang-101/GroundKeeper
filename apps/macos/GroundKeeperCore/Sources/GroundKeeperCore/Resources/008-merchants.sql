-- Exact statement descriptors are identities, not inferred business/branch aliases.
CREATE TABLE merchant_names (
  key TEXT PRIMARY KEY, label TEXT NOT NULL,
  merchant_id TEXT NOT NULL REFERENCES merchants(id),
  original_merchant_id TEXT NOT NULL REFERENCES merchants(id),
  confirmed INTEGER NOT NULL DEFAULT 0 CHECK(confirmed IN (0,1)),
  updated_at_ms INTEGER NOT NULL
) STRICT;
ALTER TABLE transactions ADD COLUMN merchant_key TEXT REFERENCES merchant_names(key);
ALTER TABLE transactions ADD COLUMN merchant_override INTEGER NOT NULL DEFAULT 0 CHECK(merchant_override IN (0,1));
ALTER TABLE transactions ADD COLUMN merchant_resolved INTEGER NOT NULL DEFAULT 0 CHECK(merchant_resolved IN (0,1));
CREATE INDEX transactions_merchant_name ON transactions(merchant_key) WHERE merchant_override=0;
CREATE TRIGGER analytics_merchant_names_update AFTER UPDATE ON merchant_names BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_merchants_update AFTER UPDATE ON merchants BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
