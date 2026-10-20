-- Receipt attachments are evidence, never monetary events. Original migrations stay immutable.
CREATE TABLE receipt_captures (
 id TEXT PRIMARY KEY, source_event_id TEXT NOT NULL UNIQUE, payload_sha256 TEXT NOT NULL,
 payload_json TEXT NOT NULL CHECK(json_valid(payload_json)), captured_at_ms INTEGER NOT NULL,
 parent_source_id TEXT NOT NULL, parent_event_id TEXT NOT NULL,
 capture_event_id TEXT REFERENCES raw_events(id), transaction_id TEXT REFERENCES transactions(id),
 image_path TEXT, image_sha256 TEXT, image_state TEXT NOT NULL DEFAULT 'not_requested'
   CHECK(image_state IN ('not_requested','pending','stored','invalid')),
 image_error TEXT, is_test INTEGER NOT NULL DEFAULT 0 CHECK(is_test IN (0,1))
) STRICT;
CREATE INDEX receipt_parent ON receipt_captures(parent_source_id,parent_event_id);
CREATE INDEX receipt_transaction ON receipt_captures(transaction_id,captured_at_ms);
CREATE TABLE receipt_ocr_runs (
 id TEXT PRIMARY KEY, receipt_id TEXT NOT NULL REFERENCES receipt_captures(id),
 producer TEXT NOT NULL, text TEXT NOT NULL, text_sha256 TEXT NOT NULL,
 created_at_ms INTEGER NOT NULL, UNIQUE(receipt_id,producer,text_sha256)
) STRICT;
CREATE TABLE receipt_images (
 receipt_id TEXT PRIMARY KEY REFERENCES receipt_captures(id), content_sha256 TEXT NOT NULL,
 content_type TEXT NOT NULL CHECK(content_type IN ('image/jpeg','image/png','image/heic')),
 image BLOB NOT NULL CHECK(length(image) BETWEEN 1 AND 8388608)
) STRICT;
-- Incremented only for receipt evidence changes, so existing model suggestions can be revisited.
ALTER TABLE classification_jobs ADD COLUMN receipt_context_sha256 TEXT;
ALTER TABLE classification_runs ADD COLUMN context_version TEXT;
