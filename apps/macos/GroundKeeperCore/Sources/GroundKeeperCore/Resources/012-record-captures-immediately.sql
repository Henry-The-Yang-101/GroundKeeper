-- A detected payment is an actual ledger entry. The internal 'posted' value
-- means recorded, not a claim that the bank has settled the payment. Keep source
-- observations and payloads intact, and do not invent a bank posting date.
UPDATE transactions SET lifecycle='posted',revision=revision+1,
  updated_at_ms=max(updated_at_ms,CAST(strftime('%s','now') AS INTEGER)*1000)
WHERE lifecycle='pending';

-- Retain the original schema for migration checksums and historical evidence,
-- while preventing the retired status from returning to canonical transactions.
CREATE TRIGGER transactions_no_pending_insert BEFORE INSERT ON transactions
WHEN NEW.lifecycle='pending' BEGIN
  SELECT RAISE(ABORT,'captured payments must be recorded immediately');
END;
CREATE TRIGGER transactions_no_pending_update BEFORE UPDATE OF lifecycle ON transactions
WHEN NEW.lifecycle='pending' BEGIN
  SELECT RAISE(ABORT,'captured payments must be recorded immediately');
END;
