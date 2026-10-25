# Swift application integration

Implemented 2026-10-17; encryption/setup added 2026-10-18. The application now
uses SQLCipher 4.19.0 with a user choice of ordinary unencrypted SQLite or a
passphrase-encrypted vault. Provisioned builds support opt-in Keychain
convenience unlock. See [setup and protection](../../docs/onboarding.md).

## Schema audit

Migration 007 extends `classification_jobs` to target exactly one model or
Council configuration, preserving existing jobs and receipt fingerprints. Its
uniqueness constraints distinguish part/revision/model and part/revision/Council.
`council_configs` and `council_config_members` store the versioned equal-vote
configuration. Registering a member can avoid changing the selected queue target.
Parent/child runs and `council_votes` retain all outcomes; only the parent may
append an assignment with `origin=council`. New `council_member_inputs` binds each
child to its frozen authorized input/hash, transaction part, revision and policy.
This permits receipt redaction for Apple without relaxing member provenance.
Input projections cannot be updated. Cancellation, crash recovery and user edits
use the same persistent queue protections as individual providers.

Migration 006 adds the optional DuckDuckGo merchant-evidence cache and per-run
search audit metadata. Cache entries expire and are bounded; run input/evidence
snapshots remain independent of cache cleanup. Search consent/locality and
cross-process cooldown/backoff live in vault settings. Merchant search and Apple
receipt sharing default to enabled when their setting is absent; saved settings
take precedence. The queue binds enriched
input and its canonical hash before inference, with original transaction/capture
data preserved. See the [search contract](../classifier/README.md#merchant-search-evidence).

The existing relational design is suitable for this scope. Keep raw events,
observations and canonical transactions separate; preserve signed integer minor
units, append-only assignments, test-event guards and source provenance. No
replacement schema is needed. Planning tables remain unused. Spending reports now query the ledger and use
the insight tables; see the spending report section below.

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
Equal-vote Council orchestration is implemented in Swift; see the
[Council contract](../classifier/README.md#council-orchestration).

The UI now loads persisted transactions, adds accounts, saves confirmed manual
edits, soft-deletes transactions, and shows pending/failed work. Transaction
lists apply search, category/account/review filters, and sorting across the ledger
before selecting pages of 500. The footer shows the matching range and total;
filter changes reset the page, and deletions clamp it to the last available page.
Home review totals and its five latest entries are queried independently of this
selection. Analytics/planning examples are no longer exposed as live data.

## Capture queue

In setup or Sync, select the exact capture directory. Existing saved bookmarks
for a parent `GroundKeeper` folder retain their original `inbox` resolution.
The app stores a read/write security-scoped bookmark. Existing read-only bookmarks
require a one-time folder reconnect to permit queue cleanup. Settings controls automatic
background processing, processing only while the app is open (the default), or
manual processing. Automatic passes run every 15 seconds. It coordinates reads, requests downloads for iCloud placeholders,
waits for stable file modification times, rejects symlinks, bounds JSON reads,
and processes at most 200 changed files per scan, draining the existing backlog
in successive batches on a processing request. An in-memory metadata cache
avoids rereading completed unchanged files; the database remains the authority
after restart. Retry clears this optimization cache.

Successfully imported source JSON and receipt images are **removed from iCloud only
after durable local storage and a matching content-hash check**. Invalid/quarantined
files remain for review. A durable cleanup journal retries failed deletions and
recovers after a crash between deletion and acknowledgement. Imported/quarantined status
is local database state. This avoids deleting the only source after a failed
write.

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
use reliable record IDs when supplied; rows without them stay separate. A
merchant/amount hash is never a purchase ID.

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
separate purchases. Only Bank App Automation ↔ Wallet Automation pairs qualify,
with an inclusive 300,000 ms capture-time window. The same restriction applies
to potential-duplicate reviews and user linking; CSV import times, manual entries,
and same-kind captures never qualify. Matching does not use a civil-date window,
so captures straddling midnight can qualify. Ties require confirmation. Both
arrival orders are supported. On vault opening, unresolved old duplicate flags
are rechecked: ineligible events become separate transactions with their original
evidence, while eligible candidate lists are refreshed. Resolved/dismissed reviews
and existing links are preserved. Replay and reliable CSV record-ID handling remain
identity checks independent of heuristic duplicate detection.

Transactions displays a Source column derived from active event links: Bank App
Automation, Wallet Automation, Manually input, or Imported from CSV. A linked
automation pair displays both labels; later category/manual edits do not relabel
the original source. Review actions link to an existing transaction,
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

## Spending reports and calculated findings

Migration 005 adds a persisted analytics revision and triggers on transactions,
parts, assignments, review items, capture links and tags. Relevant changes bump
that revision and mark current insights stale, including assignments that do not
increment a transaction revision. Existing migrations remain unchanged.

`LedgerStore.spendingReport` queries the complete ledger, independently of the
paged transaction list. Currency, account, merchant, category, tag, reporting date and
pending-state predicates are shared with paginated report evidence. Amounts stay
integer minor units in SQL; averages use Decimal. SQLite integer overflow fails
the report rather than wrapping. Splits contribute their own amounts and distinct
canonical purchases determine counts. `EXISTS` tag filters avoid join multiplication.

Known instants use the selected reporting timezone via a local SQLite scalar
function. Civil and unknown-time dates stay on their recorded date. Refunds use
their recorded date/category; unclassified transaction types are excluded and
counted separately. Posted and optionally pending expenses/refunds are included;
transfers, card payments, voided/deleted/merged records are excluded. Unreviewed
included assignments are disclosed. Queries do not establish account completeness.

Findings store rule version, metrics, scope, baseline, data revision, and supporting
transaction IDs/revisions. Current rules compare overall/category net spending
and purchase count/average size. They require at least three reviewed purchases
per equal-length period, observed history reaching the baseline, no known pending
or unclassified entries in scope, and configured absolute/relative thresholds.
Reports regenerate findings when viewed/refreshed after a ledger change. Dismissal
and seven-day snooze preferences survive recomputation and reopening. Restoring
hidden findings clears those preferences. `patterns-v1` additionally persists
merchant changes/majority, weekly trends/level shifts, and earlier-history merchant
amount outliers. Their metrics include deterministic prose, raw detector values,
ranking score, method, and the precise evidence filter. Stored period columns and
supporting IDs use that filter, including a 90-day earlier baseline for outliers.
No external AI request or notification delivery is part of this implementation.
See [analysis rules](../../docs/spending-reports.md#statistical-patterns).

The app clears report views on vault lock and rejects replies from a replaced
store. Home and Spending observe the ledger revision; evidence sheets query all
matching records in pages of 100. Report results are not built from the 500-row
transaction UI snapshot.


## Merchant identities (migration 008)

`merchant_names` maps versioned, SHA-256 normalized statement descriptor keys to
`merchants.id`, preserving `original_merchant_id`, display label, explicit
confirmation state and update time. Normalization is Unicode canonical composition,
POSIX lowercase and collapsed whitespace. Numbers, punctuation, accents and
processor prefixes remain. Generic/unknown descriptors remain unassigned.
The version is part of both descriptor and deterministic original merchant IDs.
Changing the normalizer requires an explicit migration/version strategy.

`transactions.merchant_key`, `merchant_override`, and `merchant_resolved` track
source-name matching separately from per-transaction corrections. Swift resolves
merchant identity in the same write transaction as creation/import/manual edits.
Opening an upgraded vault backfills unresolved descriptors transactionally;
preexisting non-null merchant assignments are preserved as explicit overrides.
No classifier or enrichment provider writes these identities.

Grouping is an explicit descriptor-to-merchant mapping, not fuzzy matching or
transaction deduplication. It updates all nonoverride matching transactions and
future imports. Undo restores that descriptor's original merchant. Groups do not
chain through other descriptor aliases. Per-transaction overrides (including
explicit unassigned) survive grouping and description edits; automatic reset uses
the current descriptor rule. Alias changes use an expected-current-merchant guard;
UI corrections use the transaction revision. Both increment transaction revisions,
update timestamps, write change-log audit entries, and invalidate analytics.
Merchant/name update triggers also invalidate findings. Legacy `merchant_aliases`
remains untouched; the new versioned mapping is authoritative for this workflow.

Reports group exact integer amounts by canonical merchant, count distinct canonical
expense transaction IDs across matching parts, and keep refunds separate. Unassigned
merchants use an empty-string filter key. No purchase merging is performed by
merchant grouping. See [user workflow](../../docs/spending-reports.md#merchants-and-purchase-frequency).


## Receipt management and editable notes (migration 009)

Receipt image bytes remain in `receipt_images` inside the vault (at most 8 MiB
and 40 million pixels per image). They follow vault encryption and backup;
images never enter classifier requests. The app can add JPEG, PNG and HEIC images
directly to any active transaction and run Apple OCR locally. Removing a receipt
sets `removed_at_ms`, hides it and excludes its OCR from classifier context;
Undo restores it. Removed receipts retain their local evidence for recovery.

`capture_file_cleanups` records the path and exact stored hash of each imported
JSON/image. A coordinated file operation checks the bytes again before deletion.
Changed files, symlinks and paths outside the selected inbox are never deleted.
Acknowledgements survive restarts and receipt removal. Images shared by several
pending receipts wait until all have a local copy. A later content-addressed
reference can reuse a stored image without depending on iCloud retention.

`capture_note_imports` copies each linked phone note into editable transaction
notes exactly once, including old captures during upgrade. Editing or clearing
those notes is authoritative; replay/reopen never resurrects the original text.
Raw capture notes remain immutable source evidence. Note-only edits preserve
confirmed categories, increment the transaction revision and obsolete stale jobs.
Unconfirmed suggestions can be revisited after a note/receipt change.

Classifier input adds optional `transaction_notes`, a nonblank UTF-8 excerpt of
at most 1,600 bytes, treated as untrusted purchase-purpose evidence. All selected
providers, including Council members and Apple, receive it. The separate Apple
receipt-sharing setting governs OCR only. Full notes remain editable locally.
