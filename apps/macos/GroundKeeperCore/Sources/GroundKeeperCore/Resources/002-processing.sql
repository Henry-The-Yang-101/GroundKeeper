CREATE UNIQUE INDEX queue_delivery_identity ON queue_items(relative_path,content_sha256);
CREATE INDEX reconciliation_dates ON transactions(account_id,currency,amount_minor,occurred_on) WHERE state='active';
CREATE TABLE classification_jobs (
 id TEXT PRIMARY KEY, part_id TEXT NOT NULL REFERENCES transaction_parts(id),
 input_revision INTEGER NOT NULL, model_id TEXT NOT NULL REFERENCES model_versions(id),
 status TEXT NOT NULL CHECK(status IN ('pending','running','succeeded','failed','obsolete')),
 attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at_ms INTEGER NOT NULL,
 run_id TEXT REFERENCES classification_runs(id), error_code TEXT,
 created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL,
 UNIQUE(part_id,input_revision,model_id)
) STRICT;
CREATE INDEX classification_jobs_ready ON classification_jobs(status,next_attempt_at_ms);
