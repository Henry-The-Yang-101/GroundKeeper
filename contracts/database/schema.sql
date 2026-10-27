-- Generated from GroundKeeperCore/Resources/migrations.json and its SQL migrations.
-- Do not edit. Regenerate: python -m scripts.database_schema
-- Reference only; the app installs the numbered migrations, not this file.
-- Includes initial reference data; excludes applied-migration records.

BEGIN TRANSACTION;
CREATE TABLE accounts (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, institution TEXT,
  kind TEXT NOT NULL CHECK(kind IN ('checking','savings','credit_card','loan','cash','investment','asset','other')),
  currency TEXT NOT NULL REFERENCES currencies(code),
  include_in_net_worth INTEGER NOT NULL DEFAULT 1 CHECK(include_in_net_worth IN (0,1)),
  opened_on TEXT, closed_on TEXT, created_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE analytics_revision (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL) STRICT;
INSERT INTO "analytics_revision" VALUES(1,0);
CREATE TABLE app_settings (
  key TEXT PRIMARY KEY, value_json TEXT NOT NULL CHECK(json_valid(value_json)),
  updated_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE backup_records (
  id TEXT PRIMARY KEY, relative_path TEXT NOT NULL, content_sha256 TEXT NOT NULL,
  schema_version INTEGER NOT NULL, key_manifest_version INTEGER NOT NULL,
  created_at_ms INTEGER NOT NULL, verified_at_ms INTEGER,
  status TEXT NOT NULL CHECK(status IN ('created','verified','failed','expired')), error_code TEXT
) STRICT;
CREATE TABLE balance_snapshots (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), as_of_ms INTEGER NOT NULL,
  balance_minor INTEGER NOT NULL, available_minor INTEGER,
  origin TEXT NOT NULL CHECK(origin IN ('user','import','derived')),
  import_row_id TEXT REFERENCES import_rows(id), supersedes_id TEXT REFERENCES balance_snapshots(id),
  created_at_ms INTEGER NOT NULL, note TEXT
) STRICT;
CREATE TABLE budget_filters (
  id TEXT PRIMARY KEY, version_id TEXT NOT NULL REFERENCES budget_versions(id),
  category_id TEXT REFERENCES categories(id), account_id TEXT REFERENCES accounts(id), tag_id TEXT REFERENCES tags(id),
  CHECK((category_id IS NOT NULL)+(account_id IS NOT NULL)+(tag_id IS NOT NULL)=1)
) STRICT;
CREATE TABLE budget_versions (
  id TEXT PRIMARY KEY, budget_id TEXT NOT NULL REFERENCES budgets(id), effective_from_on TEXT NOT NULL,
  effective_until_on TEXT, currency TEXT NOT NULL REFERENCES currencies(code), limit_minor INTEGER NOT NULL CHECK(limit_minor>=0),
  cadence TEXT NOT NULL CHECK(cadence IN ('week','month','year','custom')),
  timezone_id TEXT NOT NULL, week_start INTEGER NOT NULL CHECK(week_start BETWEEN 1 AND 7),
  rollover TEXT NOT NULL CHECK(rollover IN ('none','positive','all')),
  warning_fraction REAL CHECK(warning_fraction BETWEEN 0 AND 1),
  scope_json TEXT NOT NULL CHECK(json_valid(scope_json)), created_at_ms INTEGER NOT NULL,
  UNIQUE(budget_id,effective_from_on), CHECK(effective_until_on IS NULL OR effective_until_on>effective_from_on)
) STRICT;
CREATE TABLE budgets (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at_ms INTEGER NOT NULL, archived_at_ms INTEGER
) STRICT;
CREATE TABLE capture_file_cleanups (
 id TEXT PRIMARY KEY, relative_path TEXT NOT NULL, content_sha256 TEXT NOT NULL,
 kind TEXT NOT NULL CHECK(kind IN ('json','image')),
 completed_at_ms INTEGER, error_code TEXT,
 UNIQUE(relative_path,content_sha256,kind)
) STRICT;
CREATE TABLE capture_note_imports (
 event_id TEXT PRIMARY KEY REFERENCES capture_notes(event_id),
 transaction_id TEXT NOT NULL REFERENCES transactions(id)
) STRICT;
CREATE TABLE capture_notes (
 event_id TEXT PRIMARY KEY REFERENCES raw_events(id),
 text TEXT NOT NULL CHECK(length(CAST(text AS BLOB)) BETWEEN 1 AND 10000 AND instr(text,char(0))=0)
) STRICT;
CREATE TABLE categories (
  id TEXT PRIMARY KEY, code TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
  parent_id TEXT REFERENCES categories(id), description TEXT NOT NULL DEFAULT '',
  kind TEXT NOT NULL DEFAULT 'spending' CHECK(kind IN ('spending','uncategorized','other')),
  sort_order INTEGER NOT NULL DEFAULT 0, created_at_ms INTEGER NOT NULL,
  archived_at_ms INTEGER, replaced_by_id TEXT REFERENCES categories(id),
  CHECK(parent_id IS NULL OR parent_id<>id), CHECK(replaced_by_id IS NULL OR replaced_by_id<>id)
) STRICT;
INSERT INTO "categories" VALUES('groceries','groceries','Groceries',NULL,'','spending',1,0,NULL,NULL);
INSERT INTO "categories" VALUES('dining','dining','Dining & takeout',NULL,'','spending',2,0,NULL,NULL);
INSERT INTO "categories" VALUES('local_transport','local_transport','Local transport',NULL,'','spending',3,0,NULL,NULL);
INSERT INTO "categories" VALUES('vehicle','vehicle','Vehicle expenses',NULL,'','spending',4,0,NULL,NULL);
INSERT INTO "categories" VALUES('housing','housing','Housing & home upkeep',NULL,'','spending',5,0,NULL,NULL);
INSERT INTO "categories" VALUES('utilities','utilities','Utilities & communications',NULL,'','spending',6,0,NULL,NULL);
INSERT INTO "categories" VALUES('shopping','shopping','Shopping & household goods',NULL,'','spending',7,0,NULL,NULL);
INSERT INTO "categories" VALUES('medical','medical','Medical & health',NULL,'','spending',8,0,NULL,NULL);
INSERT INTO "categories" VALUES('personal_care','personal_care','Personal care',NULL,'','spending',9,0,NULL,NULL);
INSERT INTO "categories" VALUES('fitness','fitness','Fitness & sports',NULL,'','spending',10,0,NULL,NULL);
INSERT INTO "categories" VALUES('entertainment','entertainment','Entertainment & hobbies',NULL,'','spending',11,0,NULL,NULL);
INSERT INTO "categories" VALUES('software','software','Software & digital services',NULL,'','spending',12,0,NULL,NULL);
INSERT INTO "categories" VALUES('education','education','Education',NULL,'','spending',13,0,NULL,NULL);
INSERT INTO "categories" VALUES('travel','travel','Travel & accommodation',NULL,'','spending',14,0,NULL,NULL);
INSERT INTO "categories" VALUES('insurance','insurance','Insurance',NULL,'','spending',15,0,NULL,NULL);
INSERT INTO "categories" VALUES('financial','financial','Financial fees & interest',NULL,'','spending',16,0,NULL,NULL);
INSERT INTO "categories" VALUES('taxes','taxes','Taxes & government charges',NULL,'','spending',17,0,NULL,NULL);
INSERT INTO "categories" VALUES('gifts','gifts','Gifts & donations',NULL,'','spending',18,0,NULL,NULL);
INSERT INTO "categories" VALUES('other','other','Other',NULL,'','other',19,0,NULL,NULL);
CREATE TABLE category_assignments (
  id TEXT PRIMARY KEY, part_id TEXT NOT NULL REFERENCES transaction_parts(id),
  type_code TEXT NOT NULL REFERENCES transaction_types(code), category_id TEXT REFERENCES categories(id),
  origin TEXT NOT NULL CHECK(origin IN ('user','model','council','rule','import','system')),
  run_id TEXT REFERENCES classification_runs(id), rule_id TEXT REFERENCES user_rules(id),
  import_row_id TEXT REFERENCES import_rows(id), supersedes_id TEXT,
  needs_review INTEGER NOT NULL CHECK(needs_review IN (0,1)),
  selected_at_ms INTEGER NOT NULL, confirmed_at_ms INTEGER, confirmed_by TEXT, reason TEXT,
  UNIQUE(id,part_id),
  FOREIGN KEY(supersedes_id,part_id) REFERENCES category_assignments(id,part_id),
  CHECK((origin IN ('model','council'))=(run_id IS NOT NULL)),
  CHECK((origin='rule')=(rule_id IS NOT NULL)),
  CHECK(origin<>'import' OR import_row_id IS NOT NULL),
  CHECK((confirmed_at_ms IS NULL)=(confirmed_by IS NULL)),
  CHECK(origin='user' OR confirmed_at_ms IS NULL),
  CHECK(origin<>'user' OR confirmed_at_ms IS NOT NULL)
) STRICT;
CREATE TABLE change_log (
  id TEXT PRIMARY KEY, operation_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
  actor TEXT NOT NULL, reason TEXT NOT NULL, changed_at_ms INTEGER NOT NULL,
  before_json TEXT CHECK(before_json IS NULL OR json_valid(before_json)),
  after_json TEXT CHECK(after_json IS NULL OR json_valid(after_json))
) STRICT;
CREATE TABLE "classification_jobs" (
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
CREATE TABLE classification_runs (
  id TEXT PRIMARY KEY, part_id TEXT NOT NULL REFERENCES transaction_parts(id), input_revision INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('model','council')),
  model_version_id TEXT REFERENCES model_versions(id), council_config_id TEXT REFERENCES council_configs(id),
  policy_version_id TEXT NOT NULL REFERENCES policy_versions(id),
  input_json TEXT NOT NULL CHECK(json_valid(input_json)), input_sha256 TEXT NOT NULL,
  started_at_ms INTEGER NOT NULL, finished_at_ms INTEGER,
  status TEXT NOT NULL CHECK(status IN ('running','succeeded','failed','timeout','unavailable','invalid')),
  type_code TEXT REFERENCES transaction_types(code), category_id TEXT REFERENCES categories(id),
  needs_review INTEGER CHECK(needs_review IN (0,1)),
  degraded INTEGER NOT NULL DEFAULT 0 CHECK(degraded IN (0,1)), error_code TEXT,
  output_json TEXT CHECK(output_json IS NULL OR json_valid(output_json)), context_version TEXT, merchant_search_json TEXT,
  CHECK((kind='model' AND model_version_id IS NOT NULL AND council_config_id IS NULL)
    OR (kind='council' AND model_version_id IS NULL AND council_config_id IS NOT NULL)),
  CHECK(status<>'succeeded' OR (type_code IS NOT NULL AND needs_review IS NOT NULL AND finished_at_ms IS NOT NULL))
) STRICT;
CREATE TABLE council_config_members (
  config_id TEXT NOT NULL REFERENCES council_configs(id),
  model_version_id TEXT NOT NULL REFERENCES model_versions(id),
  weight REAL NOT NULL CHECK(weight>0), PRIMARY KEY(config_id,model_version_id)
) STRICT;
CREATE TABLE council_configs (
  id TEXT PRIMARY KEY, policy_version_id TEXT NOT NULL REFERENCES policy_versions(id),
  algorithm_version TEXT NOT NULL, configuration_json TEXT NOT NULL CHECK(json_valid(configuration_json)),
  created_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE council_member_inputs (
 council_run_id TEXT NOT NULL REFERENCES classification_runs(id),
 model_version_id TEXT NOT NULL REFERENCES model_versions(id),
 member_run_id TEXT NOT NULL UNIQUE REFERENCES classification_runs(id),
 input_json TEXT NOT NULL CHECK(json_valid(input_json)), input_sha256 TEXT NOT NULL,
 receipt_shared INTEGER NOT NULL CHECK(receipt_shared IN (0,1)),
 PRIMARY KEY(council_run_id,model_version_id)
) STRICT;
CREATE TABLE council_votes (
  council_run_id TEXT NOT NULL REFERENCES classification_runs(id),
  model_version_id TEXT NOT NULL REFERENCES model_versions(id), member_run_id TEXT REFERENCES classification_runs(id),
  weight REAL NOT NULL CHECK(weight>0), disposition TEXT NOT NULL CHECK(disposition IN ('valid','failed','timeout','unavailable','invalid','skipped')),
  PRIMARY KEY(council_run_id,model_version_id), UNIQUE(council_run_id,member_run_id)
) STRICT;
CREATE TABLE currencies (
  code TEXT PRIMARY KEY CHECK(length(code)=3),
  minor_units INTEGER NOT NULL CHECK(minor_units BETWEEN 0 AND 4)
) STRICT;
INSERT INTO "currencies" VALUES('CAD',2);
INSERT INTO "currencies" VALUES('USD',2);
INSERT INTO "currencies" VALUES('EUR',2);
INSERT INTO "currencies" VALUES('GBP',2);
CREATE TABLE debt_terms (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id), effective_from_on TEXT NOT NULL,
  effective_until_on TEXT, annual_rate_ppm INTEGER CHECK(annual_rate_ppm>=0), minimum_payment_minor INTEGER,
  terms_json TEXT NOT NULL CHECK(json_valid(terms_json)), created_at_ms INTEGER NOT NULL,
  UNIQUE(account_id,effective_from_on)
) STRICT;
CREATE TABLE devices (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, platform TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL, retired_at_ms INTEGER
) STRICT;
CREATE TABLE event_observations (
  id TEXT PRIMARY KEY, event_id TEXT NOT NULL REFERENCES raw_events(id), parser_version TEXT NOT NULL,
  parsed_at_ms INTEGER NOT NULL, status TEXT NOT NULL CHECK(status IN ('parsed','partial','failed')),
  amount_minor INTEGER, currency TEXT REFERENCES currencies(code),
  original_amount_minor INTEGER, original_currency TEXT REFERENCES currencies(code),
  occurred_at_ms INTEGER, occurred_on TEXT, time_precision TEXT CHECK(time_precision IN ('instant','date','unknown')),
  utc_offset_minutes INTEGER CHECK(utc_offset_minutes BETWEEN -840 AND 840), timezone_id TEXT,
  posted_on TEXT, merchant_text TEXT, description TEXT,
  account_id TEXT REFERENCES accounts(id), instrument_id TEXT REFERENCES payment_instruments(id),
  instrument_text TEXT, -- Supplied card/pass label; retain even before account mapping.
  lifecycle TEXT CHECK(lifecycle IN ('pending','posted','declined','voided','unknown')),
  external_record_id TEXT, error_code TEXT,
  CHECK((original_amount_minor IS NULL)=(original_currency IS NULL)),
  UNIQUE(event_id,parser_version), UNIQUE(id,event_id)
) STRICT;
CREATE TABLE event_receipts (
  id TEXT PRIMARY KEY, event_id TEXT NOT NULL REFERENCES raw_events(id),
  delivery_key TEXT NOT NULL UNIQUE, received_at_ms INTEGER NOT NULL,
  run_id TEXT REFERENCES processing_runs(id), payload_sha256 TEXT NOT NULL
) STRICT;
CREATE TABLE external_transaction_refs (
  id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id),
  external_account_key TEXT NOT NULL, namespace TEXT NOT NULL, external_record_id TEXT NOT NULL,
  transaction_id TEXT NOT NULL REFERENCES transactions(id), first_event_id TEXT NOT NULL REFERENCES raw_events(id),
  UNIQUE(source_id,external_account_key,namespace,external_record_id)
) STRICT;
CREATE TABLE fx_rates (
  id TEXT PRIMARY KEY, base_currency TEXT NOT NULL REFERENCES currencies(code), quote_currency TEXT NOT NULL REFERENCES currencies(code),
  as_of_on TEXT NOT NULL, numerator INTEGER NOT NULL CHECK(numerator>0), denominator INTEGER NOT NULL CHECK(denominator>0),
  source TEXT NOT NULL, observed_at_ms INTEGER NOT NULL, CHECK(base_currency<>quote_currency),
  UNIQUE(base_currency,quote_currency,as_of_on,source)
) STRICT;
CREATE TABLE geotags (
  id TEXT PRIMARY KEY, event_id TEXT REFERENCES raw_events(id), transaction_id TEXT REFERENCES transactions(id),
  latitude REAL NOT NULL CHECK(latitude BETWEEN -90 AND 90),
  longitude REAL NOT NULL CHECK(longitude BETWEEN -180 AND 180),
  horizontal_accuracy_m REAL CHECK(horizontal_accuracy_m>=0), measured_at_ms INTEGER NOT NULL,
  origin TEXT NOT NULL CHECK(origin IN ('phone_capture','user_pin','import')),
  label TEXT, created_at_ms INTEGER NOT NULL,
  CHECK((event_id IS NOT NULL)+(transaction_id IS NOT NULL)=1)
) STRICT;
CREATE TABLE goal_movements (
  id TEXT PRIMARY KEY, goal_id TEXT NOT NULL REFERENCES goals(id), account_id TEXT REFERENCES accounts(id),
  transaction_id TEXT REFERENCES transactions(id), amount_minor INTEGER NOT NULL CHECK(amount_minor<>0),
  occurred_on TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('contribution','withdrawal','allocation','release')),
  reverses_id TEXT UNIQUE REFERENCES goal_movements(id), created_at_ms INTEGER NOT NULL, note TEXT
) STRICT;
CREATE TABLE goals (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, currency TEXT NOT NULL REFERENCES currencies(code),
  target_minor INTEGER NOT NULL CHECK(target_minor>0), target_on TEXT,
  funding_method TEXT NOT NULL CHECK(funding_method IN ('allocation','contributions')),
  created_at_ms INTEGER NOT NULL, archived_at_ms INTEGER
) STRICT;
CREATE TABLE import_batches (
  id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id),
  account_scope_id TEXT REFERENCES accounts(id), -- NULL for a multi-account file.
  file_sha256 TEXT NOT NULL, original_filename TEXT NOT NULL,
  profile_id TEXT REFERENCES import_profiles(id), mapping_snapshot_json TEXT NOT NULL CHECK(json_valid(mapping_snapshot_json)),
  status TEXT NOT NULL CHECK(status IN ('preview','committed','undone','failed')),
  created_at_ms INTEGER NOT NULL, committed_at_ms INTEGER, undone_at_ms INTEGER,
  UNIQUE(source_id,account_scope_id,file_sha256)
) STRICT;
CREATE TABLE import_profiles (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, version INTEGER NOT NULL,
  mapping_json TEXT NOT NULL CHECK(json_valid(mapping_json)),
  default_account_id TEXT REFERENCES accounts(id), default_currency TEXT REFERENCES currencies(code),
  created_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE import_rows (
  id TEXT PRIMARY KEY, batch_id TEXT NOT NULL REFERENCES import_batches(id), row_number INTEGER NOT NULL CHECK(row_number>0),
  event_id TEXT REFERENCES raw_events(id),
  status TEXT NOT NULL CHECK(status IN ('pending','accepted','invalid','skipped','duplicate','undone')),
  error_code TEXT, row_json TEXT CHECK(row_json IS NULL OR json_valid(row_json)),
  UNIQUE(batch_id,row_number)
) STRICT;
CREATE TABLE insight_evidence (
  insight_id TEXT NOT NULL REFERENCES insights(id), transaction_id TEXT NOT NULL REFERENCES transactions(id),
  transaction_revision INTEGER NOT NULL, PRIMARY KEY(insight_id,transaction_id)
) STRICT;
CREATE TABLE insight_notifications (
  id TEXT PRIMARY KEY, insight_id TEXT NOT NULL REFERENCES insights(id),
  delivery_key TEXT NOT NULL UNIQUE, attempted_at_ms INTEGER NOT NULL, delivered_at_ms INTEGER, error_code TEXT
) STRICT;
CREATE TABLE insight_preferences (
  id TEXT PRIMARY KEY, merchant_id TEXT REFERENCES merchants(id), kind TEXT NOT NULL,
  settings_json TEXT NOT NULL CHECK(json_valid(settings_json)), updated_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE insights (
  id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, kind TEXT NOT NULL, currency TEXT REFERENCES currencies(code),
  period_start_on TEXT NOT NULL, period_end_on TEXT NOT NULL, timezone_id TEXT NOT NULL,
  baseline_start_on TEXT, baseline_end_on TEXT,
  metrics_json TEXT NOT NULL CHECK(json_valid(metrics_json)), caveats_json TEXT NOT NULL CHECK(json_valid(caveats_json)),
  rule_version TEXT NOT NULL, data_revision INTEGER NOT NULL, generated_at_ms INTEGER NOT NULL,
  narrative TEXT, narrative_model_version_id TEXT REFERENCES model_versions(id),
  state TEXT NOT NULL CHECK(state IN ('current','stale','dismissed','snoozed','replaced')),
  snoozed_until_ms INTEGER, replaces_id TEXT REFERENCES insights(id),
  CHECK(period_end_on>period_start_on)
) STRICT;
CREATE TABLE merchant_aliases (
  id TEXT PRIMARY KEY, merchant_id TEXT NOT NULL REFERENCES merchants(id),
  normalized_alias TEXT NOT NULL, normalization_version TEXT NOT NULL,
  source_id TEXT REFERENCES sources(id), account_id TEXT REFERENCES accounts(id),
  confirmed_at_ms INTEGER, evidence_json TEXT NOT NULL CHECK(json_valid(evidence_json))
) STRICT;
CREATE TABLE merchant_names (
  key TEXT PRIMARY KEY, label TEXT NOT NULL,
  merchant_id TEXT NOT NULL REFERENCES merchants(id),
  original_merchant_id TEXT NOT NULL REFERENCES merchants(id),
  confirmed INTEGER NOT NULL DEFAULT 0 CHECK(confirmed IN (0,1)),
  updated_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE merchant_search_cache (
  cache_key TEXT PRIMARY KEY, query_json TEXT NOT NULL, outcome TEXT NOT NULL,
  context_json TEXT, fetched_at_ms INTEGER NOT NULL, expires_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE merchants (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT REFERENCES merchants(id),
  created_at_ms INTEGER NOT NULL, archived_at_ms INTEGER
) STRICT;
CREATE TABLE model_categories (
  model_version_id TEXT NOT NULL REFERENCES model_versions(id),
  output_label TEXT NOT NULL, category_id TEXT NOT NULL REFERENCES categories(id),
  PRIMARY KEY(model_version_id,output_label)
) STRICT;
CREATE TABLE model_versions (
  id TEXT PRIMARY KEY, provider TEXT NOT NULL, model_name TEXT NOT NULL,
  execution TEXT NOT NULL CHECK(execution IN ('local','cloud')),
  revision TEXT, adapter_sha256 TEXT, package_sha256 TEXT,
  runtime_version TEXT, observed_service_version TEXT,
  configuration_json TEXT NOT NULL CHECK(json_valid(configuration_json)), created_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE part_tags (
  part_id TEXT NOT NULL REFERENCES transaction_parts(id), tag_id TEXT NOT NULL REFERENCES tags(id), PRIMARY KEY(part_id,tag_id)
) STRICT;
CREATE TABLE payment_instruments (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id),
  name TEXT NOT NULL, kind TEXT NOT NULL, last_four TEXT CHECK(last_four IS NULL OR length(last_four)=4),
  valid_from_ms INTEGER, valid_until_ms INTEGER, replaced_by_id TEXT REFERENCES payment_instruments(id)
) STRICT;
CREATE TABLE policy_versions (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, content_sha256 TEXT NOT NULL,
  definition_json TEXT NOT NULL CHECK(json_valid(definition_json)), created_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE processing_runs (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, started_at_ms INTEGER NOT NULL, finished_at_ms INTEGER,
  status TEXT NOT NULL CHECK(status IN ('running','succeeded','failed','interrupted')),
  app_version TEXT NOT NULL, error_code TEXT, counts_json TEXT CHECK(counts_json IS NULL OR json_valid(counts_json))
) STRICT;
CREATE TABLE queue_items (
  id TEXT PRIMARY KEY, relative_path TEXT NOT NULL, content_sha256 TEXT,
  event_id TEXT REFERENCES raw_events(id), state TEXT NOT NULL CHECK(state IN ('discovered','waiting','sealed','imported','quarantined','removed')),
  first_seen_at_ms INTEGER NOT NULL, last_attempt_at_ms INTEGER, next_attempt_at_ms INTEGER,
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count>=0),
  error_code TEXT, run_id TEXT REFERENCES processing_runs(id), staging_key_id TEXT REFERENCES staging_keys(id)
) STRICT;
CREATE TABLE raw_event_payloads (
  event_id TEXT PRIMARY KEY REFERENCES raw_events(id),
  payload_json TEXT NOT NULL CHECK(json_valid(payload_json)), retain_until_ms INTEGER
) STRICT;
CREATE TABLE raw_events (
  id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id),
  source_event_id TEXT NOT NULL, schema_version INTEGER NOT NULL CHECK(schema_version>0),
  event_kind TEXT NOT NULL CHECK(event_kind IN ('transaction','heartbeat','status')),
  captured_at_ms INTEGER NOT NULL, captured_offset_minutes INTEGER NOT NULL CHECK(captured_offset_minutes BETWEEN -840 AND 840),
  received_at_ms INTEGER NOT NULL, payload_sha256 TEXT NOT NULL,
  is_test INTEGER NOT NULL DEFAULT 0 CHECK(is_test IN (0,1)),
  external_account_key TEXT,
  location_status TEXT NOT NULL DEFAULT 'not_requested'
    CHECK(location_status IN ('not_requested','available','denied','unavailable','timeout')),
  UNIQUE(source_id,source_event_id)
) STRICT;
CREATE TABLE receipt_captures (
 id TEXT PRIMARY KEY, source_event_id TEXT NOT NULL UNIQUE, payload_sha256 TEXT NOT NULL,
 payload_json TEXT NOT NULL CHECK(json_valid(payload_json)), captured_at_ms INTEGER NOT NULL,
 parent_source_id TEXT NOT NULL, parent_event_id TEXT NOT NULL,
 capture_event_id TEXT REFERENCES raw_events(id), transaction_id TEXT REFERENCES transactions(id),
 image_path TEXT, image_sha256 TEXT, image_state TEXT NOT NULL DEFAULT 'not_requested'
   CHECK(image_state IN ('not_requested','pending','stored','invalid')),
 image_error TEXT, is_test INTEGER NOT NULL DEFAULT 0 CHECK(is_test IN (0,1))
, removed_at_ms INTEGER) STRICT;
CREATE TABLE receipt_images (
 receipt_id TEXT PRIMARY KEY REFERENCES receipt_captures(id), content_sha256 TEXT NOT NULL,
 content_type TEXT NOT NULL CHECK(content_type IN ('image/jpeg','image/png','image/heic')),
 image BLOB NOT NULL CHECK(length(image) BETWEEN 1 AND 8388608)
) STRICT;
CREATE TABLE receipt_ocr_runs (
 id TEXT PRIMARY KEY, receipt_id TEXT NOT NULL REFERENCES receipt_captures(id),
 producer TEXT NOT NULL, text TEXT NOT NULL, text_sha256 TEXT NOT NULL,
 created_at_ms INTEGER NOT NULL, UNIQUE(receipt_id,producer,text_sha256)
) STRICT;
CREATE TABLE reconciliation_decisions (
  id TEXT PRIMARY KEY, event_id TEXT REFERENCES raw_events(id),
  left_transaction_id TEXT REFERENCES transactions(id), right_transaction_id TEXT REFERENCES transactions(id),
  action TEXT NOT NULL CHECK(action IN ('link','unlink','merge','unmerge','not_duplicate','defer')),
  actor TEXT NOT NULL CHECK(actor IN ('user','system')), algorithm_version TEXT,
  evidence_json TEXT NOT NULL CHECK(json_valid(evidence_json)), created_at_ms INTEGER NOT NULL,
  supersedes_id TEXT REFERENCES reconciliation_decisions(id),
  CHECK(event_id IS NOT NULL OR (left_transaction_id IS NOT NULL AND right_transaction_id IS NOT NULL)),
  CHECK(left_transaction_id IS NULL OR right_transaction_id IS NULL OR left_transaction_id<>right_transaction_id)
) STRICT;
CREATE TABLE recurring_occurrences (
  id TEXT PRIMARY KEY, schedule_id TEXT NOT NULL REFERENCES recurring_schedules(id), due_on TEXT NOT NULL,
  transaction_id TEXT REFERENCES transactions(id), expected_amount_minor INTEGER,
  status TEXT NOT NULL CHECK(status IN ('expected','matched','skipped','missed')),
  UNIQUE(schedule_id,due_on)
) STRICT;
CREATE TABLE recurring_schedules (
  id TEXT PRIMARY KEY, merchant_id TEXT REFERENCES merchants(id), account_id TEXT REFERENCES accounts(id),
  name TEXT NOT NULL, currency TEXT NOT NULL REFERENCES currencies(code), expected_amount_minor INTEGER,
  cadence_json TEXT NOT NULL CHECK(json_valid(cadence_json)), timezone_id TEXT NOT NULL,
  next_due_on TEXT, status TEXT NOT NULL CHECK(status IN ('suggested','confirmed','paused','ended')),
  confirmed_at_ms INTEGER, created_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE review_items (
  id TEXT PRIMARY KEY, transaction_id TEXT REFERENCES transactions(id), event_id TEXT REFERENCES raw_events(id),
  part_id TEXT REFERENCES transaction_parts(id), reason_code TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('open','resolved','dismissed')),
  details_json TEXT NOT NULL CHECK(json_valid(details_json)),
  created_at_ms INTEGER NOT NULL, resolved_at_ms INTEGER, resolution TEXT,
  CHECK((transaction_id IS NOT NULL)+(event_id IS NOT NULL)+(part_id IS NOT NULL)=1)
) STRICT;
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY, name TEXT NOT NULL, checksum TEXT NOT NULL,
  applied_at_ms INTEGER NOT NULL
) STRICT;
CREATE TABLE source_account_mappings (
  id TEXT PRIMARY KEY, source_id TEXT NOT NULL REFERENCES sources(id),
  external_account_key TEXT NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id),
  instrument_id TEXT REFERENCES payment_instruments(id),
  valid_from_ms INTEGER NOT NULL, valid_until_ms INTEGER, confirmed_at_ms INTEGER NOT NULL,
  CHECK(valid_until_ms IS NULL OR valid_until_ms>valid_from_ms),
  UNIQUE(source_id,external_account_key,valid_from_ms)
) STRICT;
CREATE TABLE sources (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('manual','csv','apple_wallet','bank_notification','email','sms','system')),
  device_id TEXT REFERENCES devices(id), app_identifier TEXT, name TEXT NOT NULL,
  configuration_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(configuration_json)),
  created_at_ms INTEGER NOT NULL, retired_at_ms INTEGER
) STRICT;
CREATE TABLE staging_keys (
  id TEXT PRIMARY KEY, algorithm TEXT NOT NULL, public_key BLOB NOT NULL,
  private_key BLOB NOT NULL, created_at_ms INTEGER NOT NULL, retired_at_ms INTEGER
) STRICT;
CREATE TABLE tags (
  id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, kind TEXT NOT NULL DEFAULT 'custom', archived_at_ms INTEGER
) STRICT;
CREATE TABLE transaction_event_links (
  id TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id),
  event_id TEXT NOT NULL REFERENCES raw_events(id), observation_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('capture','authorization','posted','manual','import','decline','reversal')),
  decision_id TEXT NOT NULL REFERENCES reconciliation_decisions(id),
  linked_at_ms INTEGER NOT NULL, unlinked_at_ms INTEGER,
  FOREIGN KEY(observation_id,event_id) REFERENCES event_observations(id,event_id),
  CHECK(unlinked_at_ms IS NULL OR unlinked_at_ms>=linked_at_ms)
) STRICT;
CREATE TABLE transaction_parts (
  id TEXT PRIMARY KEY, transaction_id TEXT NOT NULL REFERENCES transactions(id),
  position INTEGER NOT NULL CHECK(position>=0), amount_minor INTEGER NOT NULL,
  current_assignment_id TEXT, memo TEXT NOT NULL DEFAULT '',
  UNIQUE(transaction_id,position), UNIQUE(id,transaction_id),
  FOREIGN KEY(current_assignment_id,id) REFERENCES category_assignments(id,part_id) DEFERRABLE INITIALLY DEFERRED
) STRICT;
CREATE TABLE transaction_relationships (
  id TEXT PRIMARY KEY, from_transaction_id TEXT NOT NULL REFERENCES transactions(id),
  to_transaction_id TEXT NOT NULL REFERENCES transactions(id),
  kind TEXT NOT NULL CHECK(kind IN ('refund_of','transfer_counterpart','card_payment_counterpart','reversal_of','reimbursement_of')),
  allocated_minor INTEGER CHECK(allocated_minor>0), currency TEXT REFERENCES currencies(code),
  created_at_ms INTEGER NOT NULL, retired_at_ms INTEGER,
  CHECK(from_transaction_id<>to_transaction_id), CHECK((allocated_minor IS NULL)=(currency IS NULL))
) STRICT;
CREATE TABLE transaction_tags (
  transaction_id TEXT NOT NULL REFERENCES transactions(id), tag_id TEXT NOT NULL REFERENCES tags(id),
  PRIMARY KEY(transaction_id,tag_id)
) STRICT;
CREATE TABLE transaction_types (
  code TEXT PRIMARY KEY,
  category_rule TEXT NOT NULL CHECK(category_rule IN ('required','optional','none','uncategorized'))
) STRICT;
INSERT INTO "transaction_types" VALUES('expense','optional');
INSERT INTO "transaction_types" VALUES('income','none');
INSERT INTO "transaction_types" VALUES('refund','optional');
INSERT INTO "transaction_types" VALUES('transfer','none');
INSERT INTO "transaction_types" VALUES('card_payment','none');
INSERT INTO "transaction_types" VALUES('loan_principal','none');
INSERT INTO "transaction_types" VALUES('cash_movement','none');
INSERT INTO "transaction_types" VALUES('balance_adjustment','none');
INSERT INTO "transaction_types" VALUES('unknown','optional');
CREATE TABLE transactions (
  id TEXT PRIMARY KEY, account_id TEXT REFERENCES accounts(id), instrument_id TEXT REFERENCES payment_instruments(id),
  merchant_id TEXT REFERENCES merchants(id), description TEXT NOT NULL,
  amount_minor INTEGER NOT NULL, currency TEXT NOT NULL REFERENCES currencies(code),
  original_amount_minor INTEGER, original_currency TEXT REFERENCES currencies(code),
  occurred_at_ms INTEGER, occurred_on TEXT NOT NULL,
  time_precision TEXT NOT NULL CHECK(time_precision IN ('instant','date','unknown')),
  utc_offset_minutes INTEGER CHECK(utc_offset_minutes BETWEEN -840 AND 840), timezone_id TEXT,
  posted_on TEXT, lifecycle TEXT NOT NULL CHECK(lifecycle IN ('pending','posted','declined','voided','unknown')),
  state TEXT NOT NULL DEFAULT 'draft' CHECK(state IN ('draft','active','merged','deleted')),
  merged_into_id TEXT REFERENCES transactions(id), selected_geotag_id TEXT REFERENCES geotags(id),
  notes TEXT NOT NULL DEFAULT '', revision INTEGER NOT NULL DEFAULT 1 CHECK(revision>0),
  field_provenance_json TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(field_provenance_json)),
  created_at_ms INTEGER NOT NULL, updated_at_ms INTEGER NOT NULL, deleted_at_ms INTEGER, merchant_key TEXT REFERENCES merchant_names(key), merchant_override INTEGER NOT NULL DEFAULT 0 CHECK(merchant_override IN (0,1)), merchant_resolved INTEGER NOT NULL DEFAULT 0 CHECK(merchant_resolved IN (0,1)),
  CHECK((original_amount_minor IS NULL)=(original_currency IS NULL)),
  CHECK((time_precision='instant' AND occurred_at_ms IS NOT NULL AND utc_offset_minutes IS NOT NULL)
    OR (time_precision IN ('date','unknown') AND occurred_at_ms IS NULL)),
  CHECK((state='merged')=(merged_into_id IS NOT NULL)), CHECK(merged_into_id IS NULL OR merged_into_id<>id)
) STRICT;
CREATE TABLE user_rules (
  id TEXT PRIMARY KEY, name TEXT NOT NULL, version INTEGER NOT NULL, priority INTEGER NOT NULL,
  predicate_json TEXT NOT NULL CHECK(json_valid(predicate_json)),
  type_code TEXT NOT NULL REFERENCES transaction_types(code), category_id TEXT REFERENCES categories(id),
  confirmed_at_ms INTEGER NOT NULL, retired_at_ms INTEGER, created_from_assignment_id TEXT REFERENCES category_assignments(id)
) STRICT;
CREATE UNIQUE INDEX current_source_account_mapping ON source_account_mappings(source_id,external_account_key)
  WHERE valid_until_ms IS NULL;
CREATE INDEX merchant_alias_lookup ON merchant_aliases(normalized_alias,normalization_version);
CREATE UNIQUE INDEX multi_account_import_identity ON import_batches(source_id,file_sha256) WHERE account_scope_id IS NULL;
CREATE INDEX raw_events_capture ON raw_events(source_id,captured_at_ms);
CREATE INDEX transactions_period ON transactions(currency,occurred_on,id) WHERE state='active';
CREATE INDEX transactions_account_period ON transactions(account_id,occurred_on,id) WHERE state='active';
CREATE INDEX transactions_merchant_period ON transactions(merchant_id,occurred_on,id) WHERE state='active';
CREATE INDEX reconciliation_candidates ON transactions(account_id,currency,amount_minor,occurred_at_ms) WHERE state='active';
CREATE INDEX geotags_event ON geotags(event_id);
CREATE INDEX classification_part ON classification_runs(part_id,started_at_ms);
CREATE INDEX assignments_part ON category_assignments(part_id,selected_at_ms);
CREATE INDEX assignments_category ON category_assignments(category_id,part_id);
CREATE UNIQUE INDEX one_current_transaction_per_event ON transaction_event_links(event_id) WHERE unlinked_at_ms IS NULL;
CREATE INDEX transaction_sources ON transaction_event_links(transaction_id,event_id) WHERE unlinked_at_ms IS NULL;
CREATE TRIGGER reject_test_capture_link BEFORE INSERT ON transaction_event_links
WHEN (SELECT is_test FROM raw_events WHERE id=NEW.event_id)=1 BEGIN
  SELECT RAISE(ABORT,'test captures cannot become transaction evidence');
END;
CREATE TRIGGER reject_test_capture_relink BEFORE UPDATE OF event_id ON transaction_event_links
WHEN (SELECT is_test FROM raw_events WHERE id=NEW.event_id)=1 BEGIN
  SELECT RAISE(ABORT,'test captures cannot become transaction evidence');
END;
CREATE INDEX relationship_target ON transaction_relationships(to_transaction_id,kind);
CREATE INDEX review_open ON review_items(status,created_at_ms);
CREATE INDEX change_log_entity ON change_log(entity_type,entity_id,changed_at_ms);
CREATE INDEX account_balance_history ON balance_snapshots(account_id,as_of_ms);
CREATE UNIQUE INDEX current_insight_fingerprint ON insights(fingerprint) WHERE state='current';
CREATE INDEX queue_retry ON queue_items(state,next_attempt_at_ms);
CREATE TRIGGER category_parent_cycle_insert BEFORE INSERT ON categories
WHEN NEW.parent_id IS NOT NULL BEGIN
  SELECT RAISE(ABORT,'category hierarchy cycle') WHERE NEW.parent_id=NEW.id;
END;
CREATE TRIGGER category_parent_cycle_update BEFORE UPDATE OF parent_id ON categories
WHEN NEW.parent_id IS NOT NULL BEGIN
  SELECT RAISE(ABORT,'category hierarchy cycle') WHERE NEW.id IN (
    WITH RECURSIVE ancestors(id) AS (
      SELECT NEW.parent_id UNION SELECT c.parent_id FROM categories c JOIN ancestors a ON c.id=a.id WHERE c.parent_id IS NOT NULL
    ) SELECT id FROM ancestors
  );
END;
CREATE UNIQUE INDEX one_other_category ON categories(kind) WHERE kind='other';
CREATE TRIGGER assignment_delete_guard BEFORE DELETE ON category_assignments BEGIN
  SELECT RAISE(ABORT,'retain category history');
END;
CREATE TRIGGER transaction_activation BEFORE UPDATE OF state,amount_minor,currency ON transactions
WHEN NEW.state='active' BEGIN
  SELECT RAISE(ABORT,'parts must sum to transaction amount') WHERE
    NOT EXISTS(SELECT 1 FROM transaction_parts WHERE transaction_id=NEW.id)
    OR (SELECT sum(amount_minor) FROM transaction_parts WHERE transaction_id=NEW.id)<>NEW.amount_minor;
  SELECT RAISE(ABORT,'each part needs a category/type assignment') WHERE
    EXISTS(SELECT 1 FROM transaction_parts WHERE transaction_id=NEW.id AND current_assignment_id IS NULL);
END;
CREATE TRIGGER transaction_start_draft BEFORE INSERT ON transactions WHEN NEW.state='active' BEGIN
  SELECT RAISE(ABORT,'create transaction as draft then activate');
END;
CREATE TRIGGER initial_geotag_selection BEFORE INSERT ON transactions WHEN NEW.selected_geotag_id IS NOT NULL BEGIN
  SELECT RAISE(ABORT,'attach sources before selecting geotag');
END;
CREATE TRIGGER active_part_insert BEFORE INSERT ON transaction_parts
WHEN (SELECT state FROM transactions WHERE id=NEW.transaction_id)='active' BEGIN
  SELECT RAISE(ABORT,'edit split amounts inside draft transaction');
END;
CREATE TRIGGER active_part_update BEFORE UPDATE OF amount_minor,transaction_id ON transaction_parts
WHEN (SELECT state FROM transactions WHERE id=OLD.transaction_id)='active'
  OR (SELECT state FROM transactions WHERE id=NEW.transaction_id)='active' BEGIN
  SELECT RAISE(ABORT,'edit split amounts inside draft transaction');
END;
CREATE TRIGGER active_part_delete BEFORE DELETE ON transaction_parts
WHEN (SELECT state FROM transactions WHERE id=OLD.transaction_id)='active' BEGIN
  SELECT RAISE(ABORT,'edit split amounts inside draft transaction');
END;
CREATE TRIGGER active_assignment_required BEFORE UPDATE OF current_assignment_id ON transaction_parts
WHEN NEW.current_assignment_id IS NULL AND (SELECT state FROM transactions WHERE id=NEW.transaction_id)='active' BEGIN
  SELECT RAISE(ABORT,'active part needs assignment');
END;
CREATE TRIGGER validate_geotag_selection BEFORE UPDATE OF selected_geotag_id ON transactions
WHEN NEW.selected_geotag_id IS NOT NULL BEGIN
  SELECT RAISE(ABORT,'geotag must belong to transaction or linked event') WHERE NOT EXISTS(
    SELECT 1 FROM geotags g WHERE g.id=NEW.selected_geotag_id AND (g.transaction_id=NEW.id OR EXISTS(
      SELECT 1 FROM transaction_event_links l WHERE l.event_id=g.event_id AND l.transaction_id=NEW.id AND l.unlinked_at_ms IS NULL))
  );
END;
CREATE INDEX instruments_account ON payment_instruments(account_id);
CREATE INDEX mappings_account ON source_account_mappings(account_id);
CREATE INDEX category_parent ON categories(parent_id);
CREATE INDEX receipts_event ON event_receipts(event_id);
CREATE INDEX import_row_event ON import_rows(event_id);
CREATE INDEX geotags_transaction ON geotags(transaction_id);
CREATE INDEX council_member_run ON council_votes(member_run_id);
CREATE INDEX reviews_transaction ON review_items(transaction_id,status);
CREATE INDEX reviews_part ON review_items(part_id,status);
CREATE INDEX reviews_event ON review_items(event_id,status);
CREATE INDEX relationships_from ON transaction_relationships(from_transaction_id,kind);
CREATE INDEX tags_transactions ON transaction_tags(tag_id,transaction_id);
CREATE INDEX tags_parts ON part_tags(tag_id,part_id);
CREATE INDEX goal_movements_goal ON goal_movements(goal_id,occurred_on);
CREATE INDEX recurrence_transaction ON recurring_occurrences(transaction_id);
CREATE INDEX insight_evidence_transaction ON insight_evidence(transaction_id);
CREATE INDEX current_assignments ON transaction_parts(current_assignment_id);
CREATE VIEW capture_event_details AS
SELECT e.id AS event_id,e.source_id,s.kind AS source_kind,e.schema_version,
  e.captured_at_ms,e.captured_offset_minutes,e.received_at_ms,e.is_test,
  json_extract(p.payload_json,'$.source') AS payload_source,
  json_extract(p.payload_json,'$.input_shape') AS input_shape,
  json_extract(p.payload_json,'$.app') AS app_name,
  json_extract(p.payload_json,'$.title') AS notification_title,
  json_extract(p.payload_json,'$.subtitle') AS notification_subtitle,
  json_extract(p.payload_json,'$.body') AS notification_body,
  json_extract(p.payload_json,'$.transaction') AS wallet_transaction_text,
  json_extract(p.payload_json,'$.card_or_pass') AS wallet_card_or_pass_text,
  json_extract(p.payload_json,'$.merchant') AS wallet_merchant_text,
  json_extract(p.payload_json,'$.amount') AS wallet_amount_text,
  json_extract(p.payload_json,'$.name') AS wallet_name
FROM raw_events e JOIN sources s ON s.id=e.source_id
LEFT JOIN raw_event_payloads p ON p.event_id=e.id;
CREATE VIEW current_transaction_parts AS
SELECT t.id AS transaction_id,t.account_id,t.merchant_id,t.currency,t.occurred_on,t.occurred_at_ms,
  t.time_precision,t.lifecycle,t.revision,p.id AS part_id,p.amount_minor,
  a.id AS assignment_id,a.type_code,a.category_id,a.origin,a.run_id,a.confirmed_at_ms,
  a.needs_review,
  EXISTS(SELECT 1 FROM review_items r WHERE r.status='open' AND
    (r.transaction_id=t.id OR r.part_id=p.id OR r.event_id IN (
      SELECT l.event_id FROM transaction_event_links l WHERE l.transaction_id=t.id AND l.unlinked_at_ms IS NULL
    ))) AS has_open_review
FROM transactions t JOIN transaction_parts p ON p.transaction_id=t.id
JOIN category_assignments a ON a.id=p.current_assignment_id AND a.part_id=p.id WHERE t.state='active';
CREATE VIEW spending_entries AS
SELECT *,CASE WHEN type_code='expense' THEN abs(amount_minor) ELSE -abs(amount_minor) END AS net_spending_minor
FROM current_transaction_parts WHERE type_code IN ('expense','refund') AND lifecycle='posted';
CREATE VIEW transaction_source_summary AS
SELECT l.transaction_id,s.kind,s.id AS source_id,count(*) AS event_count
FROM transaction_event_links l JOIN raw_events e ON e.id=l.event_id JOIN sources s ON s.id=e.source_id
WHERE l.unlinked_at_ms IS NULL GROUP BY l.transaction_id,s.kind,s.id;
CREATE UNIQUE INDEX queue_delivery_identity ON queue_items(relative_path,content_sha256);
CREATE INDEX reconciliation_dates ON transactions(account_id,currency,amount_minor,occurred_on) WHERE state='active';
CREATE INDEX receipt_parent ON receipt_captures(parent_source_id,parent_event_id);
CREATE INDEX receipt_transaction ON receipt_captures(transaction_id,captured_at_ms);
CREATE TRIGGER capture_notes_immutable_update BEFORE UPDATE ON capture_notes
BEGIN SELECT RAISE(ABORT,'capture notes are immutable evidence'); END;
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
CREATE INDEX merchant_search_expiry ON merchant_search_cache(expires_at_ms);
CREATE INDEX classification_jobs_ready ON classification_jobs(status,next_attempt_at_ms);
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
CREATE INDEX transactions_merchant_name ON transactions(merchant_key) WHERE merchant_override=0;
CREATE TRIGGER analytics_merchant_names_update AFTER UPDATE ON merchant_names BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER analytics_merchants_update AFTER UPDATE ON merchants BEGIN
  UPDATE analytics_revision SET revision=revision+1 WHERE id=1;
  UPDATE insights SET state='stale' WHERE state='current';
END;
CREATE TRIGGER categories_no_missing_insert BEFORE INSERT ON categories
WHEN NEW.kind='uncategorized' OR NEW.code IN ('uncategorized','none') BEGIN
  SELECT RAISE(ABORT,'missing category must be NULL');
END;
CREATE TRIGGER categories_no_missing_update BEFORE UPDATE ON categories
WHEN NEW.kind='uncategorized' OR NEW.code IN ('uncategorized','none') BEGIN
  SELECT RAISE(ABORT,'missing category must be NULL');
END;
CREATE TRIGGER assignments_append_only BEFORE UPDATE ON category_assignments BEGIN
  SELECT RAISE(ABORT,'append a new assignment instead');
END;
CREATE TRIGGER validate_assignment BEFORE INSERT ON category_assignments BEGIN
  SELECT RAISE(ABORT,'invalid type/category combination') WHERE
    ((SELECT category_rule FROM transaction_types WHERE code=NEW.type_code)='required' AND NEW.category_id IS NULL)
    OR ((SELECT category_rule FROM transaction_types WHERE code=NEW.type_code)='none' AND NEW.category_id IS NOT NULL);
  SELECT RAISE(ABORT,'missing category or unknown type requires review') WHERE NEW.needs_review=0 AND (
    NEW.type_code='unknown' OR (NEW.type_code IN ('expense','refund') AND NEW.category_id IS NULL));
  SELECT RAISE(ABORT,'AI spending decisions require a category; use Other for uncertainty')
    WHERE NEW.origin IN ('model','council') AND NEW.type_code IN ('expense','refund','unknown') AND NEW.category_id IS NULL;
  SELECT RAISE(ABORT,'AI provenance does not match decision') WHERE NEW.origin IN ('model','council') AND NOT EXISTS (
    SELECT 1 FROM classification_runs r WHERE r.id=NEW.run_id AND r.part_id=NEW.part_id
      AND r.status='succeeded' AND r.kind=NEW.origin AND r.type_code=NEW.type_code AND r.category_id IS NEW.category_id
      AND NEW.needs_review>=r.needs_review
  );
END;
CREATE TRIGGER validate_run_category_insert BEFORE INSERT ON classification_runs
WHEN NEW.status='succeeded' AND NEW.type_code IN ('expense','refund','unknown') AND NEW.category_id IS NULL BEGIN
  SELECT RAISE(ABORT,'AI spending decisions require a category');
END;
CREATE TRIGGER validate_run_category_update BEFORE UPDATE OF status,type_code,category_id ON classification_runs
WHEN NEW.status='succeeded' AND NEW.type_code IN ('expense','refund','unknown') AND NEW.category_id IS NULL BEGIN
  SELECT RAISE(ABORT,'AI spending decisions require a category');
END;
CREATE TRIGGER protect_user_assignment BEFORE UPDATE OF current_assignment_id ON transaction_parts
WHEN NEW.current_assignment_id IS NOT OLD.current_assignment_id
  AND EXISTS(SELECT 1 FROM category_assignments a WHERE a.id=OLD.current_assignment_id
    AND a.confirmed_at_ms IS NOT NULL
    AND NOT (a.needs_review=1 AND a.category_id IS NULL AND a.type_code IN ('expense','refund','unknown')))
  AND NOT EXISTS(SELECT 1 FROM category_assignments WHERE id=NEW.current_assignment_id AND origin='user') BEGIN
  SELECT RAISE(ABORT,'user-confirmed choice requires explicit user replacement');
END;
CREATE TRIGGER transactions_no_pending_insert BEFORE INSERT ON transactions
WHEN NEW.lifecycle='pending' BEGIN
  SELECT RAISE(ABORT,'captured payments must be recorded immediately');
END;
CREATE TRIGGER transactions_no_pending_update BEFORE UPDATE OF lifecycle ON transactions
WHEN NEW.lifecycle='pending' BEGIN
  SELECT RAISE(ABORT,'captured payments must be recorded immediately');
END;
COMMIT;
