# GroundKeeper plan

Updated: 2026-10-09. This is the current product direction. Architecture details
remain proposals until verified; historical evidence stays in `research/`,
`experiments/`, and [M0_SCOPE.md](M0_SCOPE.md).

## Product and scope

Build a personal spending tracker with minimal manual entry: iPhone Shortcuts
captures transactions, iCloud Drive transfers events, and a native SwiftUI Mac
app reconciles, categorizes, and displays them.

- Platforms: macOS app and iPhone Shortcuts; no native iPhone app.
- Local storage and local model inference run on the Mac. Apple Intelligence
  cloud inference is an optional user-selected mode, including within Council.
- MVP: capture, import, reconciliation, suggestions, review, spending insights,
  encrypted storage, recovery/backups, and visible capture/import failures.
- Budget limits, savings goals, net worth, receipt scanning, and direct bank
  integrations are outside the established MVP. Statement import/manual entry
  may be needed for completeness; their scope is undecided.

## Capture and data flow

```text
iPhone Wallet / CIBC alerts → GK Capture Shortcut → iCloud event queue
→ Mac parsing and classification → sealed staging
→ unlock, reconcile, and merge → encrypted database → native Mac app
```

- Save raw fields as immutable, versioned JSON using Shortcuts Dictionary
  serialization. Include a stable event ID, source, capture timestamp with
  offset, and available Wallet/bank payload fields. Keep phone capture simple.
- Verify actual Wallet Amount/currency and notification fields with real redacted
  fixtures. Trigger existence is assumed; payload availability while locked and
  delivery through Focus/Summary still need verification. Validate email/SMS as
  a fallback if notifications cannot expose the required text.
- Define the file contract in `contracts/`. A daily heartbeat helps detect broken
  capture/file transfer. A content-free bank ping is not a transaction.
- Parse observed formats on the Mac: signed integer amounts in currency minor
  units, currency, merchant, card identity, UTC time, and original offset. Keep
  source evidence; unknown formats enter review.
- Handle delayed sync, placeholders, partial writes, malformed files, and retries.
  Preserve inputs in development. Production deletes an input only after an
  atomic, durable sealed staging write; IDs/content hashes make retries harmless
  without collapsing distinct captures.

## Classification and user choice

Settings will offer four modes:

| Mode | Intended behavior |
| --- | --- |
| Fine-tuned Laya | Local instant decision model; typed decisions are serialized into the shared JSON contract. |
| Fine-tuned Qwen | Local language model using constrained JSON output. |
| Apple Intelligence Cloud | Invoke a Mac Apple Shortcut that accepts classifier input and returns decision JSON; requires internet and service availability. |
| Council | Consult all three providers and choose a decision using weighted voting, with explicit disagreement and failure handling. |

Every provider follows [TRANSACTION_CATEGORIES.md](TRANSACTION_CATEGORIES.md)
and `groundkeeper/policy.py`. Shared input: `description`, `direction`, `currency`.
Shared output: `type`, `category`, `review`.

- Use 18 spending categories plus Uncategorized/Other fallbacks. Needs review is
  a separate status; subscription/recurrence and trip/business use are tags.
- Keep income, refunds, transfers, card payments, loan principal, cash movements,
  and adjustments distinct. Refunds offset their original category when known;
  transfers/card payments do not count as new spending.
- Apply explicit user rules and confirmed merchant matching before model calls:
  normalization, exact matching, then conservative fuzzy matching. A correction
  applies to that purchase unless the user deliberately creates a broader rule.
- Models suggest decisions from available evidence. Merchant identity, amount
  sign, and payment method cannot establish missing purchase details; mixed
  retailers and ambiguous money movements need review.
- Validate every response and type/category combination. Invalid outputs,
  insufficient evidence, and uncalibrated predictions require review. Preserve
  suggested versus confirmed values and user corrections.
- Each deployed local model package must total under 3 GB decimal, including
  required adapters/tokenizer/config; runtime RAM is a separate constraint.
  Record model/adapter and policy versions. Upgrades and reclassification are
  deliberate; never silently switch a local mode to cloud processing.

### Council proposal

Give all three providers the same input and policy. Sum configurable provider
weights for valid `(type, category)` decisions and select the strongest supported
choice. Keep review separate and conservative; validate the final JSON.

- Select weights and acceptance thresholds using held-out validation and real
  calibration data. Do not directly average incomparable confidence scores or
  assume model agreement proves correctness.
- Ties, material disagreement, unsupported evidence, and provider review flags
  require review until a more specific policy is validated.
- On timeout, quota exhaustion, offline operation, or invalid output, record the
  missing provider and mark any partial result as degraded/requiring review.
  Minimum participation, retry/defer behavior, and weight normalization for
  partial results remain open decisions.
- Preserve individual decisions, participating providers, weights, versions,
  disagreement, and the final result for inspection and reproducibility.
- Council includes cloud processing. Make that clear at selection and send only
  classifier input, excluding account/card identifiers, amounts, and unrelated
  notification fields; minimize identifiers within descriptions too.

Compare all four modes on decision accuracy, review burden, latency, memory, and
availability. Synthetic scores are development evidence, not real transaction
accuracy. Private training and local inference stay on the Mac; selected cloud
modes may send minimized transaction descriptions to Apple for inference.

## Reconciliation

- Preserve raw events separately from canonical transactions. Match Wallet and
  bank events one-to-one using card/account mapping, amount, currency, time, and
  merchant evidence; validate source-specific windows on real alerts.
- Match in both directions against new and existing unlinked events. Arrival
  order must not change the result. Separate Wallet purchases remain separate,
  including same-price repeats; use chronological/FIFO pairing for equal matches.
- Review uncertain duplicates, currency conversions, tips, holds, and ambiguous
  card identities. Keep original amounts; use the confirmed bank amount in
  account currency as canonical where appropriate.
- Link declines to voided purchases when supported; flag Wallet-only purchases
  missing an expected bank confirmation. Preserve manual merges, splits, edits,
  and “not a duplicate” choices across reprocessing.
- Alerts can miss transactions or show authorizations rather than posted amounts.
  Compare a real week with the bank statement and expose unexplained gaps.

## Storage and background operation

- Proposed storage: local SQLCipher with password/recovery-key unlock, Touch ID
  after persistence/fallback tests, and inactivity auto-lock. Keep the live
  database, keys, and models outside the synced queue and Git repository.
- Derive the database key from a recovery secret; password/Touch ID slots wrap
  that key. Recovery must work with the database and recovery key even if
  keyslots are lost. Losing all unlock methods means losing the data.
- The background worker holds only a staging public key, never the database key.
  Seal results into iCloud staging; keep its private key inside the encrypted
  database. Unlock decrypts staging, applies stored rules, reconciles, and merges.
  If classification cannot run while locked, seal parsed events and classify
  after unlock. Locked Apple Shortcut execution needs a live test.
- Use a user LaunchAgent nightly (initial target: 03:00), plus processing on app
  unlock/manual sync. Verify missed-run recovery, iCloud access, and permissions
  with the actual packaged worker. Use a local run lock and one consuming Mac.
- Retry temporary failures; quarantine persistently invalid files with a visible
  reason. Make versioned encrypted backups with consistent database/keyslot
  snapshots and verify restoration on a fresh account/device.
- Minimize plaintext queue retention, indexing, and backup exposure; document
  iCloud/FileVault protection options. Logs and failure notifications exclude
  financial payloads and secrets.
- Show last successful run/capture, queue age, heartbeat, review/quarantine
  counts, provider failures, and capture gaps.

## Native app and integration

Navigation is Home, Full insights, Sync, and Settings. Proposed responsibilities:
Home overview/review; Full insights transactions and spending reports; Sync
import health/manual sync; Settings providers, rules, card mappings, and security.
Detailed page designs remain open.

Keep views in `apps/macos/`, services in `groundkeeper/`, capture exports in
`shortcuts/`, and experiments outside production app code. Define a versioned
Swift/Python worker interface before integration. The native app supersedes the
earlier FastAPI/localhost dashboard.

## Delivery gates

The app shell and model experiments exist; the end-to-end product is not connected.

| Gate | Completion evidence |
| --- | --- |
| M0: Contracts/feasibility | Real redacted payloads and CIBC formats, app/worker contract, iCloud access, provider availability, and Touch ID pass/defer decisions recorded. |
| M1: Capture | A week of real Wallet/CIBC events and daily heartbeats reaches the Mac as valid files; missing/duplicate events investigated. |
| M2: Parse/classify | Known fixtures parse correctly; unknowns preserved; provider adapters and Council obey the shared policy and failure contract. |
| M3: Reconcile | Arrival-order/repeated-purchase checks pass; a real week reconciled against the statement with coverage gaps explained. |
| M4: Encryption/recovery | Locked staging/import, wrong-key rejection, password recovery, lost-keyslot recovery, and backup restoration work end to end. |
| M5: Unattended operation | Three unattended nights, including a missed 03:00 run, preserve events; retries, provider failures, quarantine, and safe logs verified. |
| M6: App MVP | Two weeks of daily capture, review, insights, sync, and settings use without the CLI; locking and failure indicators work. |

Open decisions: final checkpoints/provider default; Council weights, thresholds,
and partial-result behavior; Apple cloud variant/Shortcut setup; app-worker
packaging; runtime paths/retention; auto-lock duration; statement import/manual
entry. CSV export and additional subcategories can follow the MVP.
