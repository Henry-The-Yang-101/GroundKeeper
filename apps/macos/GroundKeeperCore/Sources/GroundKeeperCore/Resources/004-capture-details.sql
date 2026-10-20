-- Preserve phone-authored notes independently of editable ledger notes.
CREATE TABLE capture_notes (
 event_id TEXT PRIMARY KEY REFERENCES raw_events(id),
 text TEXT NOT NULL CHECK(length(CAST(text AS BLOB)) BETWEEN 1 AND 10000 AND instr(text,char(0))=0)
) STRICT;
CREATE TRIGGER capture_notes_immutable_update BEFORE UPDATE ON capture_notes
BEGIN SELECT RAISE(ABORT,'capture notes are immutable evidence'); END;
