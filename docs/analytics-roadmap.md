# GroundKeeper analysis features

Scope proposal, updated 2026-10-19. Graphs are part of the product; the roadmap below
separates spending analysis supported by captures from planning features that
need additional data. Nothing in this document is implemented yet.

## Roadmap and graphs

| Feature | User questions and behavior | Graphs | Required data / phase |
| --- | --- | --- | --- |
| Spending over time | What did I spend today, this week/month/year, or in a custom period? Show totals, daily average, purchase count, and largest purchases. | Daily/weekly/monthly bars; cumulative spending line. | Reconciled transactions; A1. |
| Category breakdown | Where does my money go? Filter by account, category, merchant, or tag; inspect Uncategorized and pending review separately. | Ranked horizontal bars; stacked category bars over time. | Category policy and review states; A1. |
| Period comparisons | How does this week/month compare with the previous one or last year? Show dollar and percentage change with equal-period comparisons. | Side-by-side bars; current/prior cumulative lines aligned by elapsed day. | Historical transactions; A1. |
| Automatic insights | Automatically surface meaningful patterns using local calculations/rules, optionally summarized by AI; refresh after data changes and support dismiss/snooze. | Evidence-linked summary with supporting trend/comparison and transaction drill-down. | Reconciled data, coverage checks, and tested thresholds; A1 baseline, optional AI after validation. |
| Merchant and habit analysis | Which merchants cost the most? How often do I visit, what is the average purchase, and which days are expensive? | Ranked merchant bars; transaction-size distribution; optional calendar heatmap. | Normalized merchants and timestamps; A1/A2. |
| Repeated merchant spending | How many separate purchases did I make at the same merchant, how much did they total, and is the frequency increasing? Optional user-defined notices. | Purchase-count/spend trends; transaction timeline; ranked frequency bars. | Reconciled purchases and confirmed merchant aliases; A1/A2. |
| Optional receipt OCR | Opt in to extracting merchant, date, total, tax, and available line items from receipt images; confirm matches to existing purchases and proposed item/category splits. | Reviewed item/category breakdowns and receipt-backed transaction drill-down. | User-supplied receipts, on-device OCR, field review, and confirmed transaction links; later, optional. |
| Budget limits | How much remains in my overall/category budget? Set weekly, monthly, yearly, or custom-period limits and optional alerts. | Actual-versus-limit bars; cumulative spend versus planned pace; history of under/over budget. | User budget definitions and transactions; A2. |
| Recurring bills/subscriptions | What repeats, when might it recur, and did the price change? Suggest patterns for confirmation; allow manual schedules. | Upcoming-payment timeline; monthly recurring-cost bars; price-history line. | Merchant history plus confirmed cadence/amount; A2. |
| Cash flow | What income came in and expenses went out? Separate ordinary spending from debt principal, cash movements, and internal transfers. | Income/outflow bars with observed surplus line; optional waterfall. | Reviewed income and outflow coverage; A3. |
| Savings goals | How close am I to an emergency fund, trip, tuition, or purchase target? Set target/date and record allocations, contributions, and withdrawals. | Goal progress bars; actual-versus-target trajectory; required contribution per remaining period. | Explicit goal funding records or allocated account balances; A3. |
| Net worth | What do I own and owe, and how has it changed? Track accounts/assets/debts with dated balance snapshots. | Net-worth line; assets/liabilities lines; account contribution bars. | Manual/imported balance history and valuation currency; A4. |
| Debt tracking | Is the outstanding balance falling? Distinguish payments, interest, and principal; show scenarios only with supplied terms. | Debt-balance line; principal/interest bars; optional payoff scenario. | Debt snapshots, payment breakdowns, and optional rate/terms; A4. |
| Forecasts and unusual changes | Am I on pace to exceed a budget? Are there unusually large purchases or changes in merchant/category spending? | Historical trend with clearly marked projection; highlighted outliers. | Sufficient history, explicit assumptions, and user thresholds; later. |

Prioritize ranked bars over a large 18-slice pie. A small optional composition
chart may show selected categories plus a clearly labeled remainder. Graphs
should answer a question and expose their source transactions.

Repeated-spending detection counts canonical purchases, not raw capture events.
Group confirmed merchant aliases; expose count, gross/refunded/net spend,
average purchase, gaps between visits, and changes over comparable periods.
Frequent café visits do not establish a subscription. Optional notices use
user-defined frequency/spend thresholds and link to the underlying entries.
Provide tested defaults for automatic discovery without requiring setup; compare
visit frequency and average purchase size over equivalent periods without
inferring purchase contents or motivation.

## Optional receipt OCR

- Receipt capture and bounded classification context now have an implementation;
  see the [capture contract](../contracts/capture/README.md) and
  [receipt pilot](../experiments/receipts/README.md). Phone automation/camera
  behavior needs device validation. Receipt-based analytics below remain planned;
  ordinary capture and CSV import remain usable without receipts.
- Extract available merchant, date, currency, subtotal, tax, total, and line items.
  Preserve the original image, recognized text, extraction version, and available
  confidence information as source evidence. Missing or uncertain fields require
  review; never infer purchase contents from a merchant name alone.
- Suggest a link to an existing transaction before creating a new purchase;
  matching totals/dates alone do not establish identity. User confirmation is
  required for links, field corrections, and item/category splits. OCR does not
  overwrite confirmed transaction data automatically.
- Count the canonical purchase once. Item splits must reconcile to its settled
  amount, accounting for tax, tips, discounts, and currency differences where
  present. Unresolved differences remain visible and cannot silently change
  spending totals. Keep OCR local and make receipt storage/retention explicit;
  any iCloud transfer uses the user's chosen capture folder.

## Automatic insight generation

- Run local calculations after unlocked import/reconciliation and relevant edits;
  expose on-demand refresh and weekly/monthly recaps in Home/Full insights.
  Initial detectors cover repeated merchants, spending/frequency changes, and
  budget thresholds; later detectors depend on confirmed schedules and goals.
- Optional text-capable AI summarizes/prioritizes verified facts or proposes
  patterns for local validation. Arithmetic and evidence remain deterministic;
  Laya classification alone is not a narrative-generation interface. AI outages
  must not prevent displaying calculated insights.
- Record the period/baseline, supporting transactions, freshness, rule/model
  version, and data-quality caveats. Recompute after corrections or import undo.
  Insufficient history and unresolved data can suppress a finding or mark it
  provisional. Deduplicate notices and retain dismiss/snooze preferences.
- Choose insight-generation providers explicitly, independently of category
  classification. Cloud summaries use minimized inputs only with the user's
  cloud-insights choice; do not send full financial history implicitly.
- Acceptance: displayed counts/amounts match SQL, repeat captures count once,
  comparisons use equivalent periods, corrections invalidate stale findings,
  dismissals avoid repeated nudges, and AI summaries introduce no unsupported
  numeric or causal claims. Notifications are opt-in.

## Time, filtering, and chart interaction

- Offer day, week, month, quarter, year, all-time, and custom ranges; choose daily,
  weekly, or monthly grouping appropriate to the range. Support calendar periods
  and rolling 7/30/90-day views with distinct labels.
- Configure week start and reporting timezone. Store timestamps in UTC but group
  by local reporting dates; specify exclusive end boundaries and test DST.
- Compare month-to-date with the same elapsed portion of the previous period,
  and show full-period comparisons separately. Handle short months, leap years,
  missing history, and a zero comparison baseline without misleading percentages.
- Hover/select for date, exact amount, count, and category; select a bar/point to
  open filtered transactions. Support legend toggles and account/category/
  merchant/tag filters. Show active filters beside totals.
- Provide accessible labels, keyboard selection, and a table alternative. Do
  not rely on red/green alone. Bars start at zero; line scales and units are
  visible. Large datasets are aggregated in SQL and transaction lists paginated.
- Prefer native Swift Charts for standard interactive bars and lines; evaluate
  custom rendering only for chart types or interactions it cannot cover.
- Home shows a concise current-period overview, spending trend, leading
  categories, budget/goal progress when configured, and review/coverage notices.
  Full insights hosts detailed charts. Sync owns data freshness and gaps;
  Settings owns period defaults and configuration. Final layouts remain open.

## Budget limits

- Start with overall and category spending caps. The user sets amount, currency,
  period, effective date, and optional warning thresholds. Show spent, remaining,
  percent used, and overage; a cap does not move or reserve actual money.
- Initially reset limits each period. Add opt-in rollover after defining whether
  unused allowance and/or overspending carries forward. Preserve historical
  limits so a future edit does not silently rewrite old budget reports.
- A weekly cap is independent of a calendar-month cap; do not assume every month
  contains four weeks. Custom/pay-cycle periods can follow calendar support.
- Budget usage follows included spending and linked refunds. Unresolved category
  suggestions remain visibly provisional; do not present budget room as certain
  while relevant amounts or classifications are unresolved.
- Overall and category caps overlap intentionally. Never add their usage into
  one larger spending total. Optional tag/trip budgets need the same rule.
- Show a simple elapsed-time pace guide; recurring bills can make spending
  uneven. End-period projections are estimates with their assumptions shown.

## Savings and cash flow

- Goals have a name, target amount/currency, optional deadline, starting funded
  amount, and explicit dated contributions/withdrawals. Explain whether progress
  is manually earmarked money or an allocation of a measured account balance.
- A goal allocation is not another expense. A transfer between the user's
  accounts neither creates income nor increases total wealth. Prevent the same
  allocated balance being counted toward multiple goals beyond available funds.
- For dated goals, show the remaining amount and required contribution per
  remaining period; handle overdue and completed goals explicitly. Projection
  uses stated assumptions and does not promise a completion date.
- Label income minus net spending as an observed surplus, not a verified increase
  in savings. Omitted bills, debt principal, investments, cash, and missing
  captures can make that figure differ from changes in actual balances.
- Suppress definitive savings-rate/cash-flow claims when income or account
  coverage is incomplete. Show observed totals and coverage instead; distinguish
  expense analysis from an account cash-movement report.

## Net worth and balances

- Net worth is included assets minus included liabilities. Add accounts for cash,
  bank savings, investments, and other explicitly valued assets, plus positive
  amounts owed for cards/loans. Do not treat credit limits as assets.
- Start with manual dated balances; statement/balance imports can follow. A
  transaction ledger alone cannot establish starting balances, asset valuations,
  or complete debt. Goals do not replace the balance snapshot system.
- Preserve account identity, ownership/inclusion, currency, valuation date,
  source, and snapshot history. Shared/duplicate representations of an asset
  must not inflate totals. Balance edits create auditable corrections.
- Display each balance's as-of date. Mark carried-forward/stale balances and
  gaps on historical charts; never imply measurements on days without snapshots.
  Investment balance changes are not investment returns without cash-flow data.
- Keep currencies separate initially. Consolidated net worth needs dated FX
  rates, a reporting currency, and visible conversion assumptions; missing rates
  must not silently drop accounts or add incompatible currencies.

## Calculation and data-quality rules

- Include manually entered and CSV-imported transactions alongside captures,
  preserving source/batch provenance and conservative duplicate reconciliation.
  Date-only imports must not imply a known purchase time. Import previews,
  mappings, row errors, and undo behavior are scoped in [the roadmap](roadmap.md).
- User category/type corrections override AI suggestions and survive future
  processing. Retain history, refresh affected summaries, and require an explicit
  separate action before turning one correction into a merchant-wide rule.
- Compute deterministic metrics locally from canonical reconciled records;
  classification providers do not calculate dashboard totals.
- Exclude voided purchases, own-account transfers, and credit-card payments from
  spending. Separate loan principal and cash movements. Include split expenses
  exactly once and require their amounts to sum to the parent purchase.
- Show gross spending, refunds, and net spending distinctly. Default refunds to
  the date received and original category when known; unresolved refunds remain
  visible without inventing a category or backdating the original period.
- Show unresolved/unconfirmed amounts and categories separately from confirmed
  breakdowns. Capture health alone does not prove statement completeness; a
  day with no observed captures is not necessarily a verified zero-spend day.
- Do not sum currencies without an explicit conversion policy. Distinguish
  original purchase currency from the account's settled amount. Manual edits,
  reconciliation, category changes, and late arrivals update affected summaries.
- Suggested recurring payments/outliers need confirmation, not automatic edits
  or fraud claims. Unseen alerts do not prove a subscription was canceled.

## Storage additions and acceptance gates

Use the chosen SQLite/SQLCipher transaction store. Add versioned budget definitions,
goal funding/allocation records, confirmed recurring schedules, account metadata,
and dated balance snapshots; add FX observations only when conversion ships.
Provider decisions, user corrections, and sources remain inspectable. Summary
caches are rebuildable and invalidate on underlying changes.

| Phase | Completion evidence |
| --- | --- |
| A1: Spending graphs (MVP) | Time/category/merchant/repeat-purchase views and drill-down match SQL totals for captures, manual entries, and CSV imports; category corrections, period boundaries, refunds, splits, duplicates, currencies, and uncertainty are verified. |
| A2: Budgets and recurring costs | Period caps/history and warning thresholds behave correctly; suggested subscriptions are confirmed; projections are labeled. |
| A3: Goals and cash flow | Explicit funding and withdrawals reconcile; transfers are not income/spending; incomplete income is visible; allocations do not double-count funds. |
| A4: Net worth and debt | Manual/imported dated balances reconcile; liabilities, stale snapshots, inclusion, and currency handling are verified; forecasts require supplied terms. |

Before implementation, choose the first chart layouts, default week start,
refund reporting policy, budget rollover semantics, goal funding method, balance
entry/import workflow, and retention for historical snapshots. Investment
performance attribution, automated valuations, and full envelope budgeting are
separate future scopes.

## Design references

- [YNAB targets](https://support.ynab.com/how-to-use-targets-rk5kkI9ks): examples
  of recurring target cadences and funding behavior, not a specification to copy.
- [Monarch manual investment balances](https://help.monarch.com/hc/en-us/articles/41855507661076-Investments-in-Monarch): balance-based tracking alongside transactions.
- [Monarch forecasting](https://help.monarch.com/hc/en-us/articles/48344305092244-Forecasting-in-Monarch): explicit assumptions and goal/debt milestones.
- [Swift Charts](https://developer.apple.com/documentation/Charts): native charts
  with localization and accessibility support.
