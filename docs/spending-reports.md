# Spending reports

Implemented 2026-10-21; merchant identity and statistical patterns added 2026-10-24. Open **Spending** in the sidebar (⌘5). Home shows the
current month's overview using the same calculations. Transactions remains a
separate page with its existing editing and review workflow.

For a disposable walkthrough, run `./apps/macos/run-demo.sh` from the repository
root. The demo imports and categorizes fictional statements before opening
Spending; findings come from the same SQL and Swift analysis as ordinary data.
Use **Last 90 days** or **All time** for weekly patterns. See the
[demo guide](../apps/macos/README.md#fictional-spending-demo).

## Layout

The Spending page uses two staggered columns when the available report width is
at least 820 points, with more room for spending/category charts and merchants.
Findings, frequency, comparison and largest purchases occupy the supporting
column. Smaller windows and accessibility text sizes use one column. Each card
keeps its natural height; expanding findings does not stretch adjacent sections.
Chart modes and merchant search/pagination survive changes in window width.

Two findings appear initially, with a button to reveal the rest. The merchant
list displays five rows per page; search and pagination still reach every
matching merchant. Charts, filters and supporting-transaction controls retain
their existing behavior. Accessibility groups keep each card's controls together.

Validated in a uniquely identified fictional demo on 2026-10-24: normal and
wide staggered layouts, narrow single-column layout, chart-mode and merchant-
search preservation across resizing, findings expansion/collapse, merchant
pagination, and supporting-transaction sheets. The Debug build and all four
date cases in `scripts/check_spending_demo.sh` passed. Accessibility grouping
was inspected through the native accessibility tree; VoiceOver was not tested.

## Reports

- Select calendar days/weeks/months/quarters/years, completed months/years,
  rolling 7/30/90 days, all time, or a custom inclusive date range.
- See gross purchases, refunds, net spending, distinct purchase count, daily
  average, average purchase size, and the five largest matching purchases.
- Explore daily, weekly, or monthly bars and cumulative lines. Select a point
  to open the matching evidence, or use Table for exact values and keyboard access.
- Category breakdowns show ranked net spending, purchase shares, review counts,
  and stacked trends. Click a category's bar or row to open matching transaction
  portions. Hovering or scrolling over the chart does not open evidence sheets.
- Compare with the previous period or the same period a year earlier. Month to
  date uses the same elapsed days where possible. Short months and leap years
  can produce unequal periods; both date ranges and day counts are disclosed,
  and automatic change findings are suppressed for those comparisons.
- Filter accounts, merchants, categories and existing tags. Currencies remain separate.
  Reporting timezone, Monday/Sunday week start and finding
  sensitivity persist in local preferences. One currency is shown at a time.

Valid mapped Wallet and bank captures become actual transactions immediately;
no CSV import or bank-settlement confirmation is required. Existing pending
transactions are converted automatically when the updated app opens the vault.
CSV matching still helps reconcile duplicates and retain statement evidence.
Unclassified types are excluded from spending and reported separately. Unconfirmed categories
remain provisional. Refunds reduce spending on their recorded date using their
current category assignment; the report does not infer new refund links. Empty
dates mean no recorded spending, not verified zero spending.

Evidence sheets preserve filters, include refunds, expose both comparison periods,
and paginate across the full ledger. A category/tag filter on a split transaction
shows only the matching portions. Overall counts count the purchase once.

## Automatic findings

Findings describe overall or category spending changes and changes in purchase
count and average size. They use local SQL results and deterministic text.
At least three reviewed purchases in each equal-length period are required.
Unclassified or review-required data suppresses findings; the
recorded history must reach the baseline. Account completeness is never assumed.

Sensitivity requires both an absolute and percentage change:

| Setting | Minimum change in selected currency | Minimum relative change |
| --- | --- | --- |
| More findings | 10.00 | 10% |
| Balanced | 25.00 | 20% |
| Larger changes | 50.00 | 30% |

Findings link to supporting transactions. Dismiss and Snooze 7 days persist across
refreshes and reopening. Dismissals remain hidden as a calendar period grows;
snoozes remain active across moving date windows until their expiry.
Filters & reporting preferences contains Restore hidden
findings. New periods can produce new findings. Changes invalidate old findings;
views recalculate on the next refresh. Optional AI explanations and notification
delivery remain future work.

## Merchants and purchase frequency

The Merchants section ranks recorded net spending and shows distinct purchase
counts, repeats after the first purchase **within the selected period**, average
purchase amount before refunds, purchases per week over the selected period,
active purchase days, and average civil-day gap. Same-day repeats count separately
and contribute zero-day gaps. A refund does not add a purchase. “Active days” is
not a store-visit count: several purchases can occur on one day. Selecting a
merchant filters the summary, spending/frequency charts, comparisons, findings,
and transaction evidence. The frequency chart also has an exact-value table.

**Manage groups** opens the statement-name directory. Automatic identity only
normalizes Unicode composition, case and whitespace; accents, punctuation,
branch numbers, processor prefixes and other descriptor text remain significant.
Ambiguous generic labels such as “Unknown” stay unassigned. This is a reproducible
statement-name identity, not verification of the underlying legal business.
No model, web lookup or fuzzy matcher decides that two branches are the same.

Select a statement name, choose an existing merchant (or create a business/group
name), review the affected-entry count, then **Confirm grouping**. That name's
existing automatic matches and future imports will report under the chosen
merchant. **Undo this name’s grouping** restores its original identity. Rules
point directly to a merchant; grouping another statement name does not silently
move already confirmed aliases. To combine several branches under one business,
confirm each statement name against that same business.

The building icon in a report's transaction sheet corrects just that entry. It
can assign a merchant, leave it unassigned, or restore automatic matching. An
explicit correction survives later descriptor/group changes; stale editors must
refresh before saving. These choices never merge or delete purchases, rewrite
source descriptions, or change classification labels. Counts use canonical
transaction IDs, so reconciled Wallet/bank captures count once and genuine
repeat purchases remain separate.

## Statistical patterns

All detection and narrative templates run locally in Swift over the same SQL
report scope. There are no LLM calls or new analysis dependencies. The architecture
adapts the older AVA insight pipeline; see [research and design](../research/local-spending-analysis.md).

- **Merchant changes:** at least three reviewed purchases in each equal-length,
  nonoverlapping period; material amount change, or at least three additional/fewer
  purchases and a 30% count change. Shows counts and average amounts without
  inventing reasons for the change.
- **Dominant merchant:** more than 60% of gross purchase spending, with at least
  three identified merchants and ten purchases. The evidence includes other
  merchants so the share's denominator can be checked.
- **Weekly trends:** at least eight complete weeks inside the selected range,
  capped at the latest 52. Every week must contain recorded purchases. Uses a
  tie-corrected Mann–Kendall test, a conservative threshold across candidate
  series, and a material change between first-half/last-half medians. Incomplete
  boundary weeks and the current week are excluded.
- **Level shifts:** when the trend rule does not qualify, compare the last four
  complete weeks with the four before them. Every value in the newer window must
  be beyond every value in the older one, with a gap exceeding twice either
  window's median absolute deviation and a material median change. The text
  identifies the newer window, not an inferred exact change date.
- **Unusually large merchant purchases:** compare the largest purchase in view
  with 8–2,000 earlier purchases at that merchant in the 90 days before the
  selected period. Requires a material difference, an amount above every baseline
  purchase, and modified MAD score ≥3.5. Flat baselines require at least twice the
  baseline median. Category/tag-filtered views skip this detector to avoid
  comparing partial purchase amounts. A flag does not imply fraud or error.

The top candidate subspaces are bounded (overall, up to eight merchants and six
categories for weekly patterns). Candidates are ranked by bounded pattern strength
and spending share, with stable tie-breaking and duplicate amount/count patterns
suppressed per scope. Up to six findings are displayed when patterns are present;
two slots retain the existing overall/category comparisons. Ranking scores are
priorities, **not probabilities**. Hidden items are not backfilled from lower ranks.

**How this was found** explains the rule. Supporting transactions use the actual
analysis window and baseline, which may differ from the report comparison period.
Money aggregation stays in integer minor units; only statistical detection uses
floating point. Unreviewed or unclassified records suppress findings in
scope. Missing imports, seasonality, and serial dependence can still influence
patterns: none establishes account completeness, causation, a subscription, or a
forecast. These conservative gates can legitimately produce no findings.

Subscriptions, budgets, forecasts, receipt analytics and notification delivery
remain future work.

## Verification

Core tests use temporary fictional vaults and cover complete-ledger totals beyond
500 rows, refunds and excluded transaction types/currencies, category splits and
overlapping tags, immediate capture recording and legacy upgrades, UTC/local
boundaries, DST, short months, leap years, evidence, invalidation, dismissal/snooze
and persistence on reopening.

Verification on 2026-10-26: all 133 core tests passed. An ad-hoc Debug app built
successfully and its disposable recording demo showed findings, reporting filters
without pending controls, and transaction details without a payment-status row.
The normal provisioned build could not be updated because its development profile
was unavailable locally; no profile was downloaded and the live vault was not opened.

```sh
swift test --package-path apps/macos/GroundKeeperCore --scratch-path .local/macos/CoreBuild
```

The Debug-only spending preview seeds fictional history in a disposable vault
with separate preferences. All three flags below are required for this walkthrough:

```sh
open -n .local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app \
  --args --setup-preview --ui-preview --spending-preview
```

Visual checks should include minimum width, light/dark appearances, expanded
filters, negative refund bars, empty views, category trends, chart/table selection,
comparison evidence, and dismiss/snooze behavior.

Category chart regression check: scroll the breakdown under the pointer, including
scrolling directly over its bars in both directions. No sheet should open. Click
the Groceries bar and confirm the sheet shows Groceries transactions; dismiss it
and repeat the scrolling. Click a category row to confirm its action still works.
Clicks on the numeric axis outside the plot should not open a sheet.

Verified locally on 2026-10-24 for the category popup fix: the original build opened
a category sheet from scrolling alone. The fixed Debug app built successfully and
passed the regression check above in a separate disposable fictional preview.
The chart now handles explicit clicks rather than presenting sheets from macOS's
hover-driven chart value selection.

Verified locally on 2026-10-21: 43 Swift core tests and 32 Python database-schema
tests passed. The Debug app built successfully. An isolated fictional preview
was inspected in light and dark appearances and at approximately 760-point
window width. Visual checks covered the summary, spending bars/table, category
trends (including a negative refund), comparisons, evidence sheets, dismissal
without scroll reset, and the Home overview. This is Mac verification using
fictional data; no phone automation or real financial dataset was used.


Verified locally on 2026-10-24: 73 Swift core tests and 32 Python database-contract
tests passed; the Debug macOS app built. New tests cover conservative identities,
restart persistence, explicit grouping/undo, overrides and stale-editor rejection,
legacy assignment preservation, capture reconciliation, split counts, refunds,
planted trends and shifts, sparse/flat/noisy histories, earlier-only outlier
baselines, majority denominators, evidence dates and visibility preferences.
The disposable fictional UI preview verified merchant totals refreshing after
branch grouping and undo, merchant filtering, per-entry correction, and outlier evidence switching to the
actual earlier 90-day window. No real financial dataset was used for validation.
