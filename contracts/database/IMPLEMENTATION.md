# Swift application integration

Implemented 2026-10-17; encryption/setup added 2026-10-18. The application now
uses SQLCipher 4.19.0 with a user choice of ordinary unencrypted SQLite or a
passphrase-encrypted vault. Provisioned builds support opt-in Keychain
convenience unlock. See [setup and protection](../../docs/onboarding.md).

## Schema audit

The existing relational design is suitable for this scope. Keep raw events,
observations and canonical transactions separate; preserve signed integer minor
units, append-only assignments, test-event guards and source provenance. No
replacement schema is needed. Planning and analytics tables remain unused.

Only these additions were necessary, in migration 002:

- A unique `(relative_path, content_sha256)` queue delivery index, so file
  discovery cannot add repeated queue entries for unchanged deliveries.
- A date-based reconciliation index alongside the existing instant-based index,
  because statement exports provide civil dates rather than purchase instants.
- `classification_jobs`, with a unique part/revision/model identity, attempt
  count, next-attempt time, state and reference to each current run. The original
  file queue and run history did not represent durable pending inference work.

The original `schema.sql` is frozen as migration 001 in the core package.
Later schema changes must be new numbered resources, never edits to an applied
migration. Both migrations record checksums inside the same transaction as their
DDL. The runner refuses unknown databases, newer migration versions and changed
checksums. Every connection enables foreign keys, a three-second busy timeout,
WAL, full synchronous writes and in-memory temporary tables. A process lock
prevents a second app instance from recovering jobs owned by a live first one.

## Local files and ownership

Swift owns the SQLite connection on `LedgerStore`, an actor. Database work stays
off the UI actor, and no database transaction spans an XPC call. The sandboxed
app creates its database at:

`~/Library/Containers/com.groundkeeper.macos/Data/Library/Application Support/GroundKeeper/vault.sqlite`

The live database is never placed in iCloud. Python receives only the existing
description/direction/currency contract, optional receipt/Wallet category evidence,
and job/revision/model identity. It has
no database connection. Settings can explicitly select an Apple Intelligence
Shortcut provider, which receives the same input contract and is recorded
as cloud-capable. Optional Wallet category values are read from active non-test
Wallet capture payloads when claiming a classification job. They are not copied
to observation/transaction columns or merchant tables. Run audit JSON records a
source-event reference instead of the value; its input hash covers the actual
request. See [capture evidence](../capture/README.md#optional-wallet-category-evidence).
Council orchestration remains planned.

The UI now loads persisted transactions, adds accounts, saves confirmed manual
edits, soft-deletes transactions, and shows pending/failed work. Transaction
lists are paged in groups of 500; current search/filter/sort controls apply to
the loaded page. Analytics/planning examples are no longer exposed as live data.

## Capture queue

In setup or Sync, select the exact capture directory. Existing saved bookmarks
for a parent `GroundKeeper` folder retain their original `inbox` resolution.
The app stores a read-only security-scoped bookmark. Settings controls automatic
background processing, processing only while the app is open (the default), or
manual processing. Automatic passes run every 15 seconds. It coordinates reads, requests downloads for iCloud placeholders,
waits for stable file modification times, rejects symlinks, bounds JSON reads,
and processes at most 200 changed files per scan, draining the existing backlog
in successive batches on a processing request. An in-memory metadata cache
avoids rereading completed unchanged files; the database remains the authority
after restart. Retry clears this optimization cache.

Source files are **retained**, not moved or deleted. Imported/quarantined status
is local database state. This avoids deleting the only source after a failed
write. Queue removal/retention is not part of this implementation.

Read-only inventory counts pending files independently of processing and excludes
persisted imported/quarantined deliveries even after restarting. Classification
counts include eligible transactions that do not yet have jobs or a chosen model.
Manual mode does not implicitly process after imports, folder selection, model
selection or retries. A scheduler cancellation releases an in-flight classification
job without consuming an attempt, and rejects a late result from its old run.

Encrypted vaults pause background processing and require an interactive unlock.
An embedded SMAppService launch agent supports the unencrypted background mode using the
same signed executable/container. The foreground process holds a separate lease;
the agent cancels and closes its writer before the foreground opens SQLite. The
normal database ownership lock still enforces exclusion. See the macOS README
for Apple development signing setup, legacy agent migration, and tested versus
unverified behavior.

Capture parsing supports the observed version-2 `wallet_transaction_fields` and
`notification_fields`, plus version-1 `separate_fields`. Opaque event IDs remain
unchanged. ISO capture times must have offsets. Capture time is not claimed as
purchase time: automatic captures use provisional civil dates with unknown
purchase-time precision. The observed amount-only purchase format is supported;
narrative notifications, missing fields, ambiguous currency, refunds/declines
and new formats remain raw evidence for correction. `$` never establishes CAD;
a confirmed account mapping or explicit currency code is required.

Malformed captures retry up to three times with bounded backoff, then appear as
quarantined. `is_test=true` captures are stored but never create transactions.
Same source/event ID plus same bytes is a replay; changed bytes under that ID
are an identity collision, retained for review without replacing original data.

## Imports and matching

CSV supports UTF-8/BOM, comma/semicolon/tab delimiters, escaped quotes, quoted
newlines, configurable column/date/sign/decimal mapping, debit/credit columns
and optional reliable posted-record IDs. Money uses checked integer arithmetic.
The preview validates the entire file; users can skip rows, including all
invalid rows. An invalid unskipped row rolls back the entire import. File hash
plus source/account prevents reimporting a committed batch. Different exports
use reliable record IDs or review; a merchant/amount hash is never a purchase ID.

Wallet and bank captures require an explicitly chosen account, either for that
capture alone or through a remembered card mapping. Sync's **Remember this card
for future transactions** option is off by default, including when correcting
capture details. Leaving it unchecked creates no mapping; dismissing a review
also creates none. Wallet uses `card_or_pass`; the CIBC adapter's notification
`title` holds the card description and `subtitle` holds the merchant. Exact
descriptions are scoped to their source/app; matching last-four digits or similar
names never joins identities across sources. Blank descriptions cannot be saved
as rules.

Mappings stay in the local vault's existing `source_account_mappings` table.
Settings lists active mappings and lets users change their account or remove
them. Only active mappings apply when importing a new capture, including delayed
iCloud deliveries; retired rows remain as history. Mapping changes do not rewrite
saved transactions or replay pending/dismissed reviews. Assigning a capture and
optionally remembering its card commit atomically. The legacy `confirmMapping`
bulk API additionally retries open account/currency reviews for that source and
label, excluding linked captures, dismissed reviews, and identity conflicts.

Automatic linking requires one unambiguous complementary capture with the same
account, currency, amount and normalized merchant within five minutes, and no
existing capture of the incoming source kind. Separate Wallet events remain
separate purchases. CSV/date-only matches and ties require confirmation. Both
arrival orders are supported. Review actions link to an existing transaction,
keep a separate transaction, confirm a source-account mapping, correct missing
details, or dismiss an issue. Original evidence and previous observations stay
intact. A posted CSV link updates settlement status without replacing a known
purchase date or a confirmed category. Different amounts/currencies are not
silently merged; advanced FX/tip/hold reconciliation remains manual.

## Classifier scheduling

Choose a verified model package or explicitly enable an Apple Intelligence
Shortcut in Settings. The selected provider is retained across launches.
Unconfirmed system assignments enqueue one job per part/revision/
model. Each attempt records frozen input and exact model identity before XPC
execution. Successful suggestions append assignment history and always require
review. Completion checks the transaction revision and current confirmation
state in the same commit; stale results remain evidence but cannot overwrite
manual edits. Duplicate completion is idempotent.

Failures use at most three attempts with bounded backoff. Service interruptions
can reconnect/reprepare; failed jobs have an explicit retry action. On restart,
unfinished runs are marked interrupted and jobs are retried or exhausted based
on their attempt count. Classification is sequential in batches of ten between
capture scans. Local providers use the bundled GPU runtime. The Shortcut provider
invokes the named Shortcut only after explicit selection in Settings and follows
the same queue processing mode. Quota and configuration errors need an explicit
retry; providers never fall back to one another.

## Verification

```sh
swift test --package-path apps/macos/GroundKeeperCore --scratch-path .local/macos/CoreBuild
.venv/bin/python -m pytest tests/test_database_schema.py tests/test_worker.py -q
./apps/macos/run.sh
```

The Swift integration suite uses temporary synthetic databases and covers exact
money/dates/CSV quoting, migrations, process ownership, replay/collision/test
isolation, one-to-one matching in both arrival orders, CSV rollback/skips,
correction provenance, bounded classifier retries, duplicate completion,
interrupted-job recovery and protection of confirmed user edits.

`--ledger-smoke` runs the actual signed app with a temporary fictional database.
Add `--ledger-model-picker /path/to/model` to exercise one real database → XPC →
Python → persisted-assignment cycle. This does not use or change the user's
transaction database. iPhone-trigger delivery and unseen bank export formats
still require their own real-source validation.

Verified locally on 2026-10-17: nine Swift tests and 55 Python schema/worker
tests passed, the Debug app built and passed deep/strict signature verification,
and the actual signed app completed a fictional CSV → durable job → Laya XPC →
persisted review-required assignment smoke check. The primary local database was
initialized empty, with both migrations and successful integrity/foreign-key
checks. The user's iCloud folder and financial account mappings still require
selection in the app; no real transactions were imported during validation.

## Capture notes and combined capture envelopes

Migration 004 adds `capture_notes`, keyed by immutable raw event identity. Schema
4 payment envelopes may carry a `note` and/or nested `receipt`. Ingestion validates
all supplied details before storing anything, then commits the payment, note and
receipt evidence in one database transaction. Duplicate deliveries do not append
evidence; changed bytes under an existing event ID remain collisions.

Captured notes are separate from editable `transactions.notes` and appear in the
Mac's **Notes & receipts…** sheet. They follow active event-to-transaction links,
including delayed account mapping and bank/Wallet reconciliation. Test captures
cannot supply notes or receipts to live purchases. Notes remain local evidence
and are not added to classifier requests. Inline receipts use the same OCR, image
retry, revision and explicit cloud-consent rules as schema 3 attachments.

Earlier migrations and capture formats remain supported. Filename text has no
role in identity, parsing or matching; the importer accepts any JSON basename.
