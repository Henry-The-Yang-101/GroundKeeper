-- Missing categories are SQL NULL. Preserve assignment IDs, supersession links,
-- model identities, and original output JSON as historical evidence.
DROP TRIGGER assignments_append_only;
DROP TRIGGER validate_assignment;
UPDATE category_assignments SET category_id=NULL WHERE category_id IN (SELECT id FROM categories WHERE kind='uncategorized');
UPDATE classification_runs SET category_id=NULL WHERE category_id IN (SELECT id FROM categories WHERE kind='uncategorized');
UPDATE user_rules SET category_id=NULL WHERE category_id IN (SELECT id FROM categories WHERE kind='uncategorized');
DELETE FROM model_categories WHERE category_id IN (SELECT id FROM categories WHERE kind='uncategorized');
UPDATE categories SET parent_id=NULL WHERE parent_id IN (SELECT id FROM categories WHERE kind='uncategorized');
UPDATE categories SET replaced_by_id=NULL WHERE replaced_by_id IN (SELECT id FROM categories WHERE kind='uncategorized');
DELETE FROM categories WHERE kind='uncategorized';
DROP INDEX one_uncategorized_category;
UPDATE transaction_types SET category_rule='optional' WHERE code IN ('expense','unknown');

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

-- Completed historical runs can contain NULL after conversion. New successful
-- runs must obey the new contract, including Council members that do not win.
CREATE TRIGGER validate_run_category_insert BEFORE INSERT ON classification_runs
WHEN NEW.status='succeeded' AND NEW.type_code IN ('expense','refund','unknown') AND NEW.category_id IS NULL BEGIN
  SELECT RAISE(ABORT,'AI spending decisions require a category');
END;
CREATE TRIGGER validate_run_category_update BEFORE UPDATE OF status,type_code,category_id ON classification_runs
WHEN NEW.status='succeeded' AND NEW.type_code IN ('expense','refund','unknown') AND NEW.category_id IS NULL BEGIN
  SELECT RAISE(ABORT,'AI spending decisions require a category');
END;
