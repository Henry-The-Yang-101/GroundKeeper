-- Search is optional evidence; original transactions and captures remain immutable.
CREATE TABLE merchant_search_cache (
  cache_key TEXT PRIMARY KEY, query_json TEXT NOT NULL, outcome TEXT NOT NULL,
  context_json TEXT, fetched_at_ms INTEGER NOT NULL, expires_at_ms INTEGER NOT NULL
) STRICT;
CREATE INDEX merchant_search_expiry ON merchant_search_cache(expires_at_ms);
ALTER TABLE classification_runs ADD COLUMN merchant_search_json TEXT;
