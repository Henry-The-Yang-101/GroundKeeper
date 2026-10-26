-- An explicitly chosen category is protected. Leaving a spending category blank
-- for review is not a confirmation, including in vaults created before v11.
DROP TRIGGER protect_user_assignment;
CREATE TRIGGER protect_user_assignment BEFORE UPDATE OF current_assignment_id ON transaction_parts
WHEN NEW.current_assignment_id IS NOT OLD.current_assignment_id
  AND EXISTS(SELECT 1 FROM category_assignments a WHERE a.id=OLD.current_assignment_id
    AND a.confirmed_at_ms IS NOT NULL
    AND NOT (a.needs_review=1 AND a.category_id IS NULL AND a.type_code IN ('expense','refund','unknown')))
  AND NOT EXISTS(SELECT 1 FROM category_assignments WHERE id=NEW.current_assignment_id AND origin='user') BEGIN
  SELECT RAISE(ABORT,'user-confirmed choice requires explicit user replacement');
END;

INSERT INTO category_assignments(id,part_id,type_code,category_id,origin,supersedes_id,needs_review,selected_at_ms)
SELECT 'unassigned-v11:' || a.id,a.part_id,a.type_code,NULL,'system',a.id,1,a.selected_at_ms
FROM category_assignments a JOIN transaction_parts p ON p.current_assignment_id=a.id
WHERE a.origin='user' AND a.category_id IS NULL AND a.needs_review=1 AND a.type_code IN ('expense','refund','unknown');
UPDATE transaction_parts SET current_assignment_id='unassigned-v11:' || current_assignment_id
WHERE EXISTS(SELECT 1 FROM category_assignments a WHERE a.id='unassigned-v11:' || transaction_parts.current_assignment_id);
