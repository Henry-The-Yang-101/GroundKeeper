# Spending reports

Implemented 2026-10-21. Open **Spending** in the sidebar (⌘5). Home shows the
current month's overview using the same calculations. Transactions remains a
separate page with its existing editing and review workflow.

## Reports

- Select calendar days/weeks/months/quarters/years, completed months/years,
  rolling 7/30/90 days, all time, or a custom inclusive date range.
- See gross purchases, refunds, net spending, distinct purchase count, daily
  average, average purchase size, and the five largest matching purchases.
- Explore daily, weekly, or monthly bars and cumulative lines. Select a point
  to open the matching evidence, or use Table for exact values and keyboard access.
- Category breakdowns show ranked net spending, purchase shares, review counts,
  and stacked trends. Each category opens matching transaction portions.
- Compare with the previous period or the same period a year earlier. Month to
  date uses the same elapsed days where possible. Short months and leap years
  can produce unequal periods; both date ranges and day counts are disclosed,
  and automatic change findings are suppressed for those comparisons.
- Filter accounts, categories and existing tags. Currencies remain separate.
  Reporting timezone, Monday/Sunday week start, pending inclusion and finding
  sensitivity persist in local preferences. One currency is shown at a time.

Pending purchases are included by default and explicitly counted. Unclassified
types are excluded from spending and reported separately. Unconfirmed categories
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
Known pending, unclassified or review-required data suppresses findings; the
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

Merchant grouping, repeated-merchant analysis, subscriptions, budgets, forecasts,
and receipt analytics are not implemented by this feature.

## Verification

Core tests use temporary fictional vaults and cover complete-ledger totals beyond
500 rows, refunds and excluded transaction types/currencies, category splits and
overlapping tags, pending visibility, UTC/local boundaries, DST, short months,
leap years, evidence, invalidation, dismissal/snooze and persistence on reopening.

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

Verified locally on 2026-10-21: 43 Swift core tests and 32 Python database-schema
tests passed. The Debug app built successfully. An isolated fictional preview
was inspected in light and dark appearances and at approximately 760-point
window width. Visual checks covered the summary, spending bars/table, category
trends (including a negative refund), comparisons, evidence sheets, dismissal
without scroll reset, and the Home overview. This is Mac verification using
fictional data; no phone automation or real financial dataset was used.
