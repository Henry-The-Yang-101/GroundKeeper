# GroundKeeper roadmap

Product direction updated 2026-10-17; implementation status checked 2026-10-18.
The app currently uses ordinary SQLite with capture ingestion, CSV import,
reconciliation, editing, durable classification jobs, and configurable queue
processing. Local models and an explicitly selected Apple Shortcut provider are
connected. The latest app-to-Shortcut check reached Apple's usage limit;
successful inference through that path still needs verification.

Encryption, locked staging, backups, Council orchestration, and analytics below
remain future work. Their proposed data flow does not describe the current
unencrypted ledger. See the [current implementation](../contracts/database/IMPLEMENTATION.md)
and [setup guide](setup.md) for working behavior. Historical evidence stays in
`research/`, `experiments/`, and the [initial scope notes](history/m0-scope.md).

## Product and scope

Build a personal spending tracker with minimal manual entry: iPhone Shortcuts
captures transactions, iCloud Drive transfers events, and a native SwiftUI Mac
app reconciles, categorizes, and displays them.

- Platforms: macOS app and iPhone Shortcuts; no native iPhone app.
- Local storage and local model inference run on the Mac. Apple Intelligence
  cloud inference is an optional user-selected mode, including within Council.
- MVP: automatic capture, manual transaction entries, CSV transaction import,
  reconciliation, suggestions, user category corrections, review, spending
  graphs, encrypted storage, recovery/backups, and visible capture/import failures.
- Analysis roadmap: weekly/monthly/yearly graphs, budget limits, recurring costs,
  savings goals, cash flow, net worth, and automatic insights, including repeated
  merchant spending. Start with spending graphs and calculated insights; stage
  features needing income, balances, or manual input as described in
  [analytics roadmap](analytics-roadmap.md).
- Receipt scanning and direct bank integrations remain outside the established
  MVP. Manual entries and CSV imports provide a way to fill capture gaps and
  load historical transactions; supported bank CSV formats remain to be chosen.

## Planned capture and encrypted data flow

```text
iPhone Wallet / CIBC alerts → GK Capture Shortcut → iCloud event queue
→ Mac parsing and classification → sealed staging
→ unlock, reconcile, and merge → encrypted database → native Mac app
```

- Save raw fields as immutable, versioned JSON using Shortcuts Dictionary
  serialization. Include a stable event ID, source, capture timestamp with
  offset, and available Wallet/bank payload fields. Keep phone capture simple.
- The capture Shortcut now writes version-2 envelopes with two branches:
  `source=wallet_transaction`, `input_shape=wallet_transaction_fields` carries
  `transaction`, `card_or_pass`, `merchant`, `amount`, `name`, and `app`;
  `source=bank_notification`, `input_shape=notification_fields` carries `title`,
  `subtitle`, `body`, and `app`. Use direct Wallet transaction automation.
  The referenced Shortcut work verified sample branch output; real iPhone tap
  and locked-phone capture still need verification. Location remains planned.
- Map wire source `wallet_transaction` to database source kind `apple_wallet`.
  Store the original envelope once; parse amount/currency/merchant/card hints
  into observations and resolve card labels to instruments only when supported.
  Card or Pass is a supplied label, not guaranteed last-four/full-card data;
  Wallet `transaction` text is not a unique purchase ID. Preserve opaque hashed
  event IDs unchanged. Mark `is_test` samples and exclude them from transactions.
- At transaction capture, also attempt to obtain the phone's current location
  and include an optional geotag in the iCloud event: latitude, longitude,
  measurement timestamp and horizontal accuracy when available. Record whether
  location was available, denied, unavailable, timed out or not requested.
  Bound the attempt and save the transaction even when location fails. Verify
  the actual Shortcuts fields and locked-phone behavior with real fixtures.
- Treat the geotag as phone location at capture time; delayed bank notifications
  may arrive elsewhere. Preserve candidate samples from each source and choose
  one optional transaction display geotag with provenance/user override. Keep
  location out of classifier/cloud inputs by default; provide capture opt-out,
  removal and retention behavior covering queued/raw data and backups.
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

## Manual entries, CSV import, and corrections

- Users can add transactions in the Mac app with date/time, amount, currency,
  account, merchant/description, transaction type, category, and optional notes
  or tags. Preserve date-only precision where no exact time is known; validate
  required fields and type/category combinations. A user-selected category is
  confirmed; otherwise offer the selected classifier's suggestion or review.
- CSV import supports a preview and column mapping for date, description,
  amount or debit/credit columns, currency, account, and optional source ID/type/
  category. Specify date format, decimal separators, and amount-sign convention;
  remember reusable mappings. Missing currency/account can use an explicit
  user-selected default. Missing purpose/category enters classification/review.
- Validate rows before commit. Show accepted, invalid, and possible-duplicate
  rows with reasons, allow corrections or explicit skipping, and report the
  imported/skipped/rejected counts. Preserve batch/row provenance and support
  undoing an import without erasing independently captured evidence or edits.
- Reimporting the same batch must be idempotent. Reconcile overlapping CSV,
  manual, Wallet, and bank records conservatively using source IDs and account/
  amount/date/merchant evidence. Identical purchases can be legitimate; a
  date-only match or repeated merchant is not enough to delete or merge a row.
- Users can edit entries and override any AI-assigned category or transaction
  type. Retain the original suggestion/provider and the correction history.
  User-confirmed values take precedence and survive reclassification/imports.
- Correcting a purchase does not create a merchant-wide rule automatically.
  Offer a separate explicit action to apply a rule to future purchases, with
  an optional reviewed preview of historical changes. Refresh affected budgets,
  graphs, and review status after edits; unrelated review reasons remain open.

## Classification and user choice

Settings will offer four modes:

| Mode | Intended behavior |
| --- | --- |
| Fine-tuned Laya | Local instant decision model; typed decisions are serialized into the shared JSON contract. |
| Fine-tuned Qwen | Local language model using constrained JSON output. |
| Apple Intelligence Cloud | Invoke a Mac Apple Shortcut that accepts classifier input and returns decision JSON; requires internet and service availability. |
| Council | Consult all three providers and choose a decision using weighted voting, with explicit disagreement and failure handling. |

Every provider follows [transaction category policy](transaction-categories.md)
and `groundkeeper/policy.py`. Shared input: `description`, `direction`, `currency`.
Shared output: `type`, `category`, `review`.

- Use 18 spending categories plus Uncategorized/Other fallbacks. Needs review is
  a separate status; subscription/recurrence and trip/business use are tags.
- Store categories as expandable reference rows with stable IDs/codes, editable
  names, optional parent categories and archival/replacement metadata. Adding a
  category must not require an SQL table migration. Version model vocabularies
  and policy separately; existing models do not automatically support new labels.
- Retain append-only type/category assignment history per transaction part.
  Record selection origin (user, model, Council, explicit rule, import or system),
  timestamp, confirmation and superseded choice. AI selections reference the
  exact model/provider/revision/adapter/runtime and policy through a saved run;
  Council selections retain configuration, member decisions/weights and failures.
  Accepting or correcting an AI suggestion appends a user-confirmed choice while
  preserving the original suggestion. Reprocessing cannot overwrite that choice.
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

### Council design

Council explicitly selects Qwen, Laya and an Apple Intelligence Shortcut under
`groundkeeper-18-v1`. Version `council-equal-v1` gives each provider weight 1.
Vote on complete `(type, category)` pairs; never combine independently winning
fields. Two matching valid decisions produce a suggestion. Three different
answers, a tie, or only one valid response produce no council consensus.
All suggestions require review, including unanimous results. User-confirmed
choices are preserved. Review flags and vote shares are not confidence scores.

- Retrieve optional DuckDuckGo evidence once per transaction attempt and freeze
  it in the parent run. Members receive the same saved search snapshot; retries
  reuse it, rather than searching again. Search remains a separate opt-in and
  failure continues with original evidence. Shared snippets can cause correlated
  errors; agreement does not verify merchant identity or purchased items.
- Preserve the common evidence snapshot and each member's actual authorized
  input/hash. Local members may use receipt context; Apple receives receipt text
  only with the separate receipt-sharing consent. Bind each child run to its
  saved projection and the parent transaction/revision/policy.
- Coordinate bounded batches in Swift, retaining one heavyweight local model
  at a time. Registering members does not select an individual provider or retire
  another member's jobs. Only the parent result can create a Council assignment.
- Record member identities, equal weights, valid outputs, timeouts, invalid
  responses and unavailable/skipped providers. Two agreeing valid members with
  a missing third produce a degraded suggestion requiring review. Do not
  normalize one surviving member into consensus. No consensus leaves the current
  assignment in place and exposes alternatives for review and explicit retry.
- Cancellation and process interruption release work through the persistent
  queue without applying incomplete results. Revision/confirmation checks prevent
  late results from replacing edits. Apple quota/configuration failures do not
  trigger immediate retry loops or silently change the selected mode.
- Selection discloses Apple processing and shows Qwen/Laya package readiness
  and the configured Shortcut. Search and receipt consent remain separate.
  Transaction details show member suggestions, failures and saved search sources.
  Avoid confidence percentages and user-facing weight sliders in this version.
- Future weights require the same independently reviewed validation cases for
  every member, including shared retrieval evidence and unseen merchants. Compare
  equal voting, weighted voting and individual models; reserve an untouched test
  set. Model size, synthetic scores and incomparable self-confidence values do
  not establish weights. Apple's underlying serving model is not pinned.

Compare all four modes on decision accuracy, review burden, latency, memory, and
availability. Synthetic scores are development evidence, not real transaction
accuracy. Private training and local inference stay on the Mac; selected cloud
modes may send minimized transaction descriptions to Apple for inference.

## Reconciliation

- Preserve raw events separately from canonical transactions. Match Wallet and
  bank events one-to-one using card/account mapping, amount, currency, time, and
  merchant evidence; validate source-specific windows on real alerts.
- One transaction can retain several source events (Wallet, bank alert, posted
  CSV row, manual entry) without multiplying spending. Deduplicate delivery by
  stable source/event ID; quarantine changed content under the same ID. Reliable
  source record IDs use account-scoped namespaces. Content hash, merchant,
  location, date and amount are not unique purchase keys. Store link/merge/
  not-duplicate decisions and preserve reversibility/history.
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

- Storage choice: SQLite with SQLCipher encryption as the primary local store.
  Use explicit schema migrations, foreign keys, and uniqueness constraints.
  Support password/recovery-key unlock, Touch ID after persistence/fallback
  tests, and inactivity auto-lock. Keep the live
  database, keys, and models outside the synced queue and Git repository.
- Proposed relational design: [database schema](../contracts/database/SCHEMA.md)
  and [executable SQL fixture](../contracts/database/schema.sql). It covers raw
  evidence, multi-source reconciliation, optional geotags, expandable categories,
  model/Council/user provenance, monetary splits, imports/undo, review/audit,
  planning/insights and operational records. It is a design artifact validated
  with ordinary SQLite fixtures; app integration, migrations, SQLCipher and
  service-level workflow invariants remain to be implemented and verified.
- Proposed ownership: Swift app services own database access/migrations; Python
  workers receive classifier inputs and return decisions. Locked background
  workers write sealed staging without access to the live database key.
- The local classification bridge now has a bundled XPC target hosting isolated
  CPython, a Swift actor client and explicit Settings diagnostics. Qwen runs on
  MLX Metal; Laya runs on PyTorch MPS, with GPU availability required. See the
  [bridge contract](../contracts/classifier/README.md). The service has no database
  access. Swift transaction/job integration, durable retries, and an explicit Apple
  Shortcut adapter are implemented. Council orchestration and locked staging
  remain future work. Release uses
  same-team signing/library validation; local ad hoc Debug has development-only
  exceptions. The pinned native runtime currently requires macOS 26.2+ and arm64.
- Store transactions, raw events/import provenance, accounts/card mappings,
  merchants/rules, provider decisions, corrections/review, budget versions,
  goals/funding allocations, recurring schedules, and balance snapshots in
  related tables. Keep model weights, training datasets, and bulky attachments
  outside the database; define retention for full provider responses.
- Design for large histories: indexed date/account/category/merchant queries
  and reconciliation lookups, paginated transaction lists, short batched writes,
  and SQL chart aggregation. Use WAL with controlled writer access; keep summary
  caches rebuildable. Verify responsiveness with realistic 100,000-row and
  million-row fixtures, including imports, reconciliation, charts, and backups.
  Treat those as test targets, not demonstrated performance guarantees.
- Keep the live SQLite database on the Mac, outside iCloud Drive. Sync immutable
  capture/staging files and completed encrypted backups; create consistent
  snapshots through the database API rather than copying an active database.
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

## Insights and graphs

Spending reports, category breakdowns, period comparisons, and local overall/category
findings are implemented; see [current behavior](spending-reports.md). Merchant
analysis and the planning features below remain future scope.

Graphs are core product features, computed locally from reconciled transactions
and user-provided planning/balance data. Deliver spending graphs first, then
budgets/recurring costs, goals/cash flow, and net worth/debt.

| Insight | Planned behavior and graphs |
| --- | --- |
| Time-based spending | Day/week/month/quarter/year/all-time/custom and rolling 7/30/90-day views; totals, average spend, purchase count, daily/weekly/monthly bars, and cumulative lines. |
| Category breakdown | Ranked category bars, stacked trends, and account/category/merchant/tag filters; show Uncategorized and provisional suggestions explicitly. |
| Period comparisons | Dollar/percentage changes, side-by-side bars, and cumulative lines; compare equal elapsed portions separately from complete periods. |
| Automatic insights | Proactively surface meaningful spending patterns and changes using local calculations/rules, with optional AI explanations; evidence-linked summaries on Home and Full insights. |
| Merchant and repeated spending | Identify frequently visited merchants; purchase counts, total/net spend, average ticket, typical gap between purchases, and frequency changes; ranked bars, spend/visit trends, and transaction timelines. |
| Habits and distribution | Day-of-week patterns, largest purchases, transaction-size distributions, and an optional calendar heatmap, with drill-down to individual entries. |
| Optional receipt OCR | Later, opt-in on-device extraction of receipt fields and line items, with user-confirmed purchase matching and item/category splits; preserve source evidence and avoid counting linked receipts as new purchases. See [receipt OCR scope](analytics-roadmap.md#optional-receipt-ocr). |
| Budget limits | Overall/category caps for weekly/monthly/yearly/custom periods, remaining allowance, overage, optional warnings, actual-versus-limit bars, spending pace, and budget history. |
| Recurring bills/subscriptions | Suggest repeating payments for confirmation, support manual cadence, show upcoming-payment timelines, monthly recurring totals, and price-history lines. |
| Cash flow | Income and outflow bars, observed surplus trend, and optional waterfall; distinguish spending from internal transfers, debt principal, and cash movements. |
| Savings goals | Target amount/date, explicit contributions/withdrawals or funded allocations, progress bars, actual-versus-target lines, and required contributions per remaining period. |
| Net worth | Assets minus liabilities using dated manual/imported balances; net-worth and asset/liability lines plus account contribution bars. |
| Debt | Outstanding balance trends, principal/interest bars where known, and optional payoff scenarios using supplied terms. |
| Forecasts/unusual changes | Later: clearly labeled end-period estimates and unusual purchase/category/merchant changes, using sufficient history and explicit assumptions. |

### Automatic insights

- Generate insights automatically after unlocked import/reconciliation and when
  corrections change the data; support on-demand refresh and weekly/monthly
  recaps.
- Start with deterministic SQL/statistical rules for repeated merchants,
  category/merchant spend changes, purchase frequency, average purchase size,
  and budget thresholds. Add recurring-price changes, goal progress, and other
  findings as their required data becomes available.
- Optional AI can summarize, prioritize, or suggest patterns to verify. All
  amounts, counts, comparisons, and supporting evidence must come from local
  calculations; validate any AI-proposed finding before displaying it as fact.
  The feature remains useful without AI or when a provider is unavailable.
- Select text-capable local/cloud providers separately from transaction
  classification. Laya's decision output does not establish narrative-generation
  capability. Cloud insight generation requires an explicit user choice and
  minimized inputs; permission to categorize one transaction does not authorize
  sending the user's financial history to a cloud model.
- Each insight shows its period, comparison baseline, freshness, supporting
  transactions/chart, and relevant coverage/review caveats. Missing history,
  unresolved duplicates, or category uncertainty must not create definite claims.
- Rank material findings, suppress repeats, and support dismiss/snooze and
  configurable sensitivity. Notifications are opt-in; avoid repeated nudges for
  the same unchanged pattern. Findings do not automatically edit transactions.
- Store insight type, evidence references, calculated metrics, data/rule/model
  versions, and dismissal state. Invalidate or replace stale findings after
  edits/import undo rather than continuing to display outdated conclusions.

### Repeated merchant spending

- Group confirmed merchant identities and carefully reviewed aliases; do not
  merge different businesses or purposes simply because names look similar.
  Analyze canonical purchases after deduplication so Wallet plus bank capture
  counts once, while separate repeated purchases still count individually.
- Surface concrete summaries such as “8 purchases at this café this month,
  totaling $64,” with purchase-count and spend comparisons to the prior period.
  Track refunds separately and show net spend as well as gross purchases.
- Detect frequent merchants automatically across supported weekly/monthly and
  custom ranges. Explain observed changes in purchase count versus average
  purchase size when the data supports that breakdown; do not infer motivation
  or item-level price inflation from a changing average receipt.
- Distinguish frequent discretionary purchases from scheduled subscriptions:
  repeated visits alone do not establish a recurring bill or a future payment.
- Let users choose merchant-specific frequency/spend thresholds and periods;
  provide tested defaults so setup is optional. Show findings on Home and Full
  insights with spend/frequency graphs and transaction drill-down. Notices are
  optional; initial detection uses transparent counts/rules, while more advanced
  patterns need testing.

### Shared analysis rules

- Support configurable week start/reporting timezone, visible units/filters,
  hover or selection for exact values, and chart-to-transaction drill-down.
  Prefer native Swift Charts for standard bars/lines, accessible labels,
  keyboard interaction, and a table alternative. Avoid an unreadable 18-slice pie.
- Budget caps initially reset per period; optional rollover needs explicit
  rules. Preserve historical limits. Overlapping overall/category/tag budgets
  never create additional spending, and a cap does not reserve actual money.
- Goal allocations are not expenses and cannot allocate the same funds beyond
  available balances. Income minus net spending is an observed surplus, not
  proof of saved money. Incomplete income/capture coverage must remain visible.
- Net worth needs asset/debt balances, starting values, valuation dates, and
  account inclusion; transaction captures alone are insufficient. Start with
  manual dated snapshots, label stale/carried-forward values, and distinguish
  investment balance changes from investment returns.
- Exclude voids, own-account transfers, and card payments from spending; keep
  principal/cash movements separate. Splits must sum to their parent amount.
  Show gross spending/refunds/net spending; default refunds to date received
  and original category when known. Do not silently backdate or invent labels.
- Keep currencies separate until dated FX conversion is specified. Handle
  zero baselines, short months, DST, partial periods, missing history, and
  unresolved transactions explicitly. Corrections/imports invalidate summaries.
- Forecasts are estimates, repeated-payment suggestions need confirmation, and
  gaps are not proof of zero spending or canceled subscriptions.

[analytics roadmap](analytics-roadmap.md) retains expanded data requirements
and A1–A4 acceptance criteria; this plan includes the full feature roadmap.

## Native app and integration

Navigation is Home, Full insights, Sync, and Settings. Proposed responsibilities:
Home overview/review; Full insights transactions and spending reports; Sync
import preview/history/health and manual sync; Settings providers, rules, card
mappings, and security. Transaction views support adding/editing entries and
correcting AI categories.
Detailed page designs remain open.

Graphs are a core feature. Home will summarize the selected period, budget/goal
progress, and items needing attention. Full insights will provide interactive
time-series, category/merchant breakdowns, and comparisons, with drill-down to
the underlying transactions. Savings and net-worth graphs require explicit
contribution or balance data; captured spending alone cannot establish them.
See [analytics roadmap](analytics-roadmap.md) for chart designs, data needs,
calculation rules, and phased acceptance criteria.

Keep views in `apps/macos/`, services in `groundkeeper/`, capture exports in
the planned `shortcuts/` directory, and experiments outside production app code.
The versioned Swift/Python worker interface is defined in the
[classifier contract](../contracts/classifier/README.md). The native app
supersedes the earlier FastAPI/localhost dashboard.

## Delivery gates

Capture ingestion, CSV import, editing, SQLite persistence, and classification
jobs are connected. The gates below still include work on real-device capture,
encryption, analytics, recovery, and broader operational testing.

| Gate | Completion evidence |
| --- | --- |
| M0: Contracts/feasibility | Real redacted payloads and CIBC formats, app/worker contract, iCloud access, provider availability, and Touch ID pass/defer decisions recorded. |
| M1: Capture | A week of real Wallet/CIBC events and daily heartbeats reaches the Mac as valid files; missing/duplicate events investigated. |
| M2: Parse/classify | Known fixtures parse correctly; unknowns preserved; provider adapters and Council obey the shared policy and failure contract. |
| M3: Reconcile and user input | Manual entries, CSV preview/mapping/import/undo, duplicate handling, and sticky category corrections work; arrival-order/repeated-purchase checks pass; a real week reconciled against the statement with gaps explained. |
| M4: Encryption/recovery | Locked staging/import, wrong-key rejection, password recovery, lost-keyslot recovery, and backup restoration work end to end. |
| M5: Unattended operation | Three unattended nights, including a missed 03:00 run, preserve events; retries, provider failures, quarantine, and safe logs verified. |
| M6: App MVP | Two weeks of capture, manual entry, CSV import, category correction, review, spending/repeated-merchant graphs, automatic calculated insights, sync, and settings without the CLI; insight evidence, refresh/dismissal, locking, failure indicators, and large-history checks work. Optional AI explanations must match calculated facts and respect provider/privacy choices. |

Open decisions: final checkpoints/provider default; Council weights, thresholds,
and partial-result behavior; Apple cloud variant/Shortcut setup; public app/model
distribution; retention; auto-lock duration; supported CSV mappings;
budget rollover; goal funding; balance entry/import formats; repeated-spending
thresholds; insight sensitivity, ranking, and text-generation provider. CSV
export and additional subcategories can follow the MVP.
