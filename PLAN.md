# GroundKeeper plan

Updated: 2026-10-17. This is the current product direction. Architecture details
remain proposals until verified; historical evidence stays in `research/`,
`experiments/`, and [M0_SCOPE.md](M0_SCOPE.md).

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
  [ANALYSIS_FEATURES.md](ANALYSIS_FEATURES.md).
- Receipt scanning and direct bank integrations remain outside the established
  MVP. Manual entries and CSV imports provide a way to fill capture gaps and
  load historical transactions; supported bank CSV formats remain to be chosen.

## Capture and data flow

```text
iPhone Wallet / CIBC alerts → GK Capture Shortcut → iCloud event queue
→ Mac parsing and classification → sealed staging
→ unlock, reconcile, and merge → encrypted database → native Mac app
```

- Save raw fields as immutable, versioned JSON using Shortcuts Dictionary
  serialization. Include a stable event ID, source, capture timestamp with
  offset, and available Wallet/bank payload fields. Keep phone capture simple.
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

Every provider follows [TRANSACTION_CATEGORIES.md](TRANSACTION_CATEGORIES.md)
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
- Proposed relational design: [database schema](contracts/database/SCHEMA.md)
  and [executable SQL fixture](contracts/database/schema.sql). It covers raw
  evidence, multi-source reconciliation, optional geotags, expandable categories,
  model/Council/user provenance, monetary splits, imports/undo, review/audit,
  planning/insights and operational records. It is a design artifact validated
  with ordinary SQLite fixtures; app integration, migrations, SQLCipher and
  service-level workflow invariants remain to be implemented and verified.
- Proposed ownership: Swift app services own database access/migrations; Python
  workers receive classifier inputs and return decisions. Locked background
  workers write sealed staging without access to the live database key.
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

[ANALYSIS_FEATURES.md](ANALYSIS_FEATURES.md) retains expanded data requirements
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
See [ANALYSIS_FEATURES.md](ANALYSIS_FEATURES.md) for chart designs, data needs,
calculation rules, and phased acceptance criteria.

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
| M3: Reconcile and user input | Manual entries, CSV preview/mapping/import/undo, duplicate handling, and sticky category corrections work; arrival-order/repeated-purchase checks pass; a real week reconciled against the statement with gaps explained. |
| M4: Encryption/recovery | Locked staging/import, wrong-key rejection, password recovery, lost-keyslot recovery, and backup restoration work end to end. |
| M5: Unattended operation | Three unattended nights, including a missed 03:00 run, preserve events; retries, provider failures, quarantine, and safe logs verified. |
| M6: App MVP | Two weeks of capture, manual entry, CSV import, category correction, review, spending/repeated-merchant graphs, automatic calculated insights, sync, and settings without the CLI; insight evidence, refresh/dismissal, locking, failure indicators, and large-history checks work. Optional AI explanations must match calculated facts and respect provider/privacy choices. |

Open decisions: final checkpoints/provider default; Council weights, thresholds,
and partial-result behavior; Apple cloud variant/Shortcut setup; app-worker
packaging; runtime paths/retention; auto-lock duration; supported CSV mappings;
budget rollover; goal funding; balance entry/import formats; repeated-spending
thresholds; insight sensitivity, ranking, and text-generation provider. CSV
export and additional subcategories can follow the MVP.
