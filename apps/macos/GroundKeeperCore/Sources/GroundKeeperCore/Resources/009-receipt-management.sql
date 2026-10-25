-- Canonical editable notes inherit each captured note exactly once.
CREATE TABLE capture_note_imports (
 event_id TEXT PRIMARY KEY REFERENCES capture_notes(event_id),
 transaction_id TEXT NOT NULL REFERENCES transactions(id)
) STRICT;
ALTER TABLE receipt_captures ADD COLUMN removed_at_ms INTEGER;
-- Durable acknowledgements are independent of receipt removal and vault reopen.
CREATE TABLE capture_file_cleanups (
 id TEXT PRIMARY KEY, relative_path TEXT NOT NULL, content_sha256 TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('json','image')),
 completed_at_ms INTEGER, error_code TEXT,
 UNIQUE(relative_path,content_sha256,kind)
) STRICT;
