# Swift application integration

Implemented 2026-10-17. The current application uses **ordinary SQLite**, as
requested. SQLCipher, Keychain key storage, encryption and unlock flows are
deferred. The encryption sections of the original design describe future work.

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
description/direction/currency contract and job/revision/model identity. It has
no database connection. No cloud classifier or Council is enabled.

The UI now loads persisted transactions, adds accounts, saves confirmed manual
edits, soft-deletes transactions, and shows pending/failed work. Transaction
lists are paged in groups of 500; current search/filter/sort controls apply to
the loaded page. Analytics/planning examples are no longer exposed as live data.

## Capture queue

In Sync, select the existing `GroundKeeper` folder or its `inbox` directory.
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

An embedded SMAppService launch agent supports the background mode using the
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

Wallet and bank source labels must be explicitly mapped to real accounts.
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

Choose a verified model package in Settings. Its bookmark and package identity
are retained. Unconfirmed system assignments enqueue one job per part/revision/
model. Each attempt records frozen input and exact model identity before XPC
execution. Successful suggestions append assignment history and always require
review. Completion checks the transaction revision and current confirmation
state in the same commit; stale results remain evidence but cannot overwrite
manual edits. Duplicate completion is idempotent.

Failures use at most three attempts with bounded backoff. Service interruptions
can reconnect/reprepare; failed jobs have an explicit retry action. On restart,
unfinished runs are marked interrupted and jobs are retried or exhausted based
on their attempt count. Classification is sequential in batches of ten between
capture scans; no automatic network service or external Shortcut invocation runs.

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
