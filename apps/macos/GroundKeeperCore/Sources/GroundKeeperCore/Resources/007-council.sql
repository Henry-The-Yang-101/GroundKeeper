-- One queue, with either a model or a Council configuration as its target.
CREATE TABLE classification_jobs_v7 (
 id TEXT PRIMARY KEY, part_id TEXT NOT NULL REFERENCES transaction_parts(id),
 input_revision INTEGER NOT NULL, model_id TEXT REFERENCES model_versions(id),
 council_config_id TEXT REFERENCES council_configs(id),
 status TEXT NOT NULL CHECK(status IN ('pending','running','succeeded','failed','obsolete')),
 attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at_ms INTEGER NOT NULL,
 run_id TEXT REFERENCES classification_runs(id), error_code TEXT,
 created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, receipt_context_sha256 TEXT,
 CHECK((model_id IS NOT NULL)+(council_config_id IS NOT NULL)=1),
 UNIQUE(part_id,input_revision,model_id), UNIQUE(part_id,input_revision,council_config_id)
) STRICT;
INSERT INTO classification_jobs_v7
 SELECT id,part_id,input_revision,model_id,NULL,status,attempts,next_attempt_at_ms,
 run_id,error_code,created_at_ms,updated_at_ms,receipt_context_sha256 FROM classification_jobs;
DROP TABLE classification_jobs;
ALTER TABLE classification_jobs_v7 RENAME TO classification_jobs;
CREATE INDEX classification_jobs_ready ON classification_jobs(status,next_attempt_at_ms);

-- A member's authorized input can omit receipt evidence present in the parent.
-- Bind each child to its frozen projection, rather than weakening hash checks.
CREATE TABLE council_member_inputs (
 council_run_id TEXT NOT NULL REFERENCES classification_runs(id),
 model_version_id TEXT NOT NULL REFERENCES model_versions(id),
 member_run_id TEXT NOT NULL UNIQUE REFERENCES classification_runs(id),
 input_json TEXT NOT NULL CHECK(json_valid(input_json)), input_sha256 TEXT NOT NULL,
 receipt_shared INTEGER NOT NULL CHECK(receipt_shared IN (0,1)),
 PRIMARY KEY(council_run_id,model_version_id)
) STRICT;
CREATE TRIGGER validate_council_input BEFORE INSERT ON council_member_inputs BEGIN
 SELECT RAISE(ABORT,'invalid Council input provenance') WHERE NOT EXISTS (
  SELECT 1 FROM classification_runs c
  JOIN council_config_members m ON m.config_id=c.council_config_id
  JOIN classification_runs r ON r.id=NEW.member_run_id
  WHERE c.id=NEW.council_run_id AND c.kind='council' AND c.status='running'
  AND m.model_version_id=NEW.model_version_id AND r.kind='model'
  AND r.model_version_id=m.model_version_id AND r.part_id=c.part_id
  AND r.input_revision=c.input_revision AND r.policy_version_id=c.policy_version_id
  AND r.input_json=NEW.input_json AND r.input_sha256=NEW.input_sha256
 );
END;
CREATE TRIGGER immutable_council_input BEFORE UPDATE ON council_member_inputs BEGIN
 SELECT RAISE(ABORT,'Council inputs are immutable');
END;
DROP TRIGGER validate_council_vote;
CREATE TRIGGER validate_council_vote BEFORE INSERT ON council_votes BEGIN
 SELECT RAISE(ABORT,'invalid Council member provenance') WHERE NOT EXISTS (
  SELECT 1 FROM classification_runs c JOIN council_config_members m ON m.config_id=c.council_config_id
  WHERE c.id=NEW.council_run_id AND c.kind='council'
   AND m.model_version_id=NEW.model_version_id AND m.weight=NEW.weight
   AND (NEW.member_run_id IS NULL OR EXISTS (
    SELECT 1 FROM classification_runs r WHERE r.id=NEW.member_run_id AND r.kind='model'
     AND r.part_id=c.part_id AND r.input_revision=c.input_revision
     AND r.policy_version_id=c.policy_version_id AND r.model_version_id=NEW.model_version_id
     AND (r.input_sha256=c.input_sha256 OR EXISTS (
      SELECT 1 FROM council_member_inputs i WHERE i.council_run_id=c.id
       AND i.model_version_id=r.model_version_id AND i.member_run_id=r.id
       AND i.input_sha256=r.input_sha256 AND i.input_json=r.input_json
     ))
   ))
 );
 SELECT RAISE(ABORT,'valid vote needs successful member run') WHERE NEW.disposition='valid' AND NOT EXISTS (
  SELECT 1 FROM classification_runs WHERE id=NEW.member_run_id AND status='succeeded'
 );
END;
