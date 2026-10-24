# GroundKeeper macOS UX audit — 2026-10-24

## Verdict

The largest problems are inconsistent transaction state, missing context at financial decisions, and navigation that loses the user's place. Three defects deserve attention first: capture correction replaces a known historical date with today, transaction filtering and Home review counts depend on the loaded page, and the editor accepts a money-out refund. The updated Spending layout remained readable at the tested widths; its clearest interaction defect is merchant pagination moving the requested results out of view. The previously reported popup-while-scrolling behavior was **not reproduced** during this audit.

This is an observation report, not an implementation. All 13 prioritized findings are **quality defects**. No finding depends on assuming how the interface was designed, and no palette, font, or design-system replacement is proposed.

## Build and isolation

- Ran `./apps/macos/run-demo.sh --instance ux-audit`, then rebuilt with `--instance ux-audit-layout` after the request to audit the new Spending layout.
- The updated app was built at approximately 04:12 EDT from `62acdb0` (`Refine Spending layout breakpoints and card accessibility`). Screenshots 11 onward show that build. Earlier screenshots are labeled where relevant; source corroboration below uses `62acdb0`.
- Computer interactions targeted the unique bundle IDs `com.groundkeeper.demo.a6d4d5f7-a1af-4ee1-ba7f-39395aab44d8` and, after rebuilding, `com.groundkeeper.demo.be40839e-9f9f-4df6-97cb-f6dfa627cea5`. They did not target another GroundKeeper instance by display name.
- Used the fictional preview vault, `examples/transactions.csv`, and three generated fictional capture files. No live capture inbox, real financial records, model download, external search, or cloud inference was used.
- Both launcher builds succeeded. No application code was changed for this audit.
- Cleanup verification is recorded at the end of this report.

## Checked scope

| Area | States and interactions inspected |
|---|---|
| Home | Populated dashboard, saved/review counts, recent entries, consistency after changing transaction pages, Spending overview |
| Transactions | Native table, selection and double-click editor, Needs review filter, account/category choices, pagination, long merchant names, new/edit forms, amount validation, currency/account consistency, direction/type choices, notes, unsaved-change confirmation, delete warning (cancelled) |
| Spending controls | This month, Last 90 days, Last year with no spending, Custom including a one-day range, filter disclosure, merchant filtering and clearing, reporting preferences |
| Spending reports | Bars/Cumulative/Table, purchase-frequency table and date drilldown, category Breakdown/Over time and evidence, comparison periods, largest purchases, supporting transactions including an unusual purchase's earlier baseline |
| Findings and merchants | Expanded six findings, dismiss and restore, evidence sheets, merchant search and pagination, grouping confirmation and undo, per-entry merchant correction controls |
| Updated Spending layout | Default roughly 1140×800, wide roughly 1512×949, half-width roughly 761×949 logical points; single/two-column reflow, expanded findings, search/expansion state across resizing, light/dark/system appearance, sidebar hidden/restored |
| CSV import | File selection, column/account/date-format mapping, valid and invalid previews, skipping invalid rows, Back preserving mapping, disabled import with no valid selected rows, successful five-row fictional import |
| Capture review | Folder connection to disposable fixtures, manual queue processing, missing-account review, remembering a fictional card mapping, possible-duplicate resolution against the imported CSV, unreadable amount correction form |
| Receipts | Captured multiline note, receipt-text disclosure and producer label on the imported fictional capture |
| Settings | Appearance, queue controls, vault protection sheet, provider/model setup and council choices, accounts including duplicate-name and USD cases, populated card-mapping controls, setup and iPhone guides |
| Setup | All seven pages, Back/Continue, optional model/phone/folder steps, existing protection choice, account creation and final summary; iPhone guide including optional CIBC instructions |

“Inspected” does not mean every external operation was executed. Limits are listed below. Screenshot sizes are Retina pixels; dimensions above are approximate window sizes in logical points. The audit was driven through Computer, with source inspection used to explain observed behavior.

## Prioritized findings

| Priority | ID | Finding | Main harm |
|---|---|---|---|
| P1 | [UX-12](#ux-12--capture-correction-resets-known-facts) | Capture correction resets known facts | Historical date can be replaced while fixing another field |
| P1 | [UX-04](#ux-04--ledger-wide-actions-use-a-single-loaded-page) | Ledger-wide actions use a single loaded page | False empty results, false review counts, stale “recent” entries |
| P1 | [UX-03](#ux-03--refund-and-direction-can-contradict-each-other) | Refund and direction can contradict each other | The list and reporting interpret the same entry differently |
| P2 | [UX-13](#ux-13--capture-reconciliation-hides-the-facts-needed-to-decide) | Capture reconciliation hides decision context | Users must link or separate records without comparing amounts/accounts |
| P2 | [UX-05](#ux-05--duplicate-account-names-are-indistinguishable) | Duplicate accounts are indistinguishable | Accidental assignment to a different account is hard to detect or repair |
| P2 | [UX-11](#ux-11--process-queue-does-not-explain-manual-categorization) | Process queue gives no provider guidance | Imported entries remain waiting after an apparently actionable command |
| P2 | [UX-07](#ux-07--merchant-pagination-loses-the-results-above-the-viewport) | Merchant pagination loses the results | The requested next page is no longer visible |
| P2 | [UX-02](#ux-02--merchant-drilldown-hides-the-return-path) | Merchant drilldown hides the return path | Returning to the full report requires discovering a collapsed control |
| P2 | [UX-06](#ux-06--report-evidence-is-a-dead-end-for-transaction-inspection) | Report evidence stops short of transaction detail | Investigating a finding requires leaving and searching again |
| P2 | [UX-08](#ux-08--review-setup-restarts-a-gated-flow-without-an-exit) | Review setup restarts a gated flow | Reviewing instructions requires traversing setup and reapplying protection |
| P2 | [UX-09](#ux-09--currency-mismatch-disables-save-without-an-explanation) | Currency mismatch silently disables Save | A valid-looking form provides no recovery explanation |
| P2 | [UX-01](#ux-01--merchant-search-retains-an-editable-hidden-selection) | Merchant search retains an editable hidden selection | An empty result list can still edit an invisible selection |
| P2 | [UX-10](#ux-10--csv-confirmation-omits-destination-and-totals) | CSV confirmation omits destination and totals | The final import decision lacks a compact verification summary |

### UX-12 — Capture correction resets known facts

**Reproduce:** Import an older capture, then open **Correct capture details…**. Tested both a valid `Maple Corner Cafe` capture from **2026-10-01**, amount **CAD 6.75**, and an unreadable-amount capture from **2026-10-03**.

**Observed:** Only the description is prefilled. Both correction forms show **2026-10-24**, a blank amount, Money out, and Choose account. The original date/raw amount is not visible alongside the instructions to check against the original capture. Entering the missing information and accepting the displayed date would save today rather than the capture's date. That save consequence is confirmed by the source; an incorrect date was not deliberately saved.

**Small correction:** Preserve every successfully parsed field and show the original source facts while editing. Require deliberate input where parsing actually failed.

**Evidence:** [Valid older capture](evidence/20-valid-capture-correction-blanks-amount.jpg), [unreadable amount](evidence/19-capture-correction-resets-date.jpg). `Features/Sync/SyncView.swift:98` initializes `date = Date()`, `amount = ""`, and `isDebit = true`; line 147 copies only the description on appearance. The save action passes that date to `workspace.correct`.

### UX-04 — Ledger-wide actions use a single loaded page

**Reproduce:** Add one Needs review entry to the populated demo. Enable **Needs review**, then advance to the next transaction page. Open Home while that page is loaded.

**Observed:** Page 1 reports **1 transaction**, yet Next remains available. Page 2 reports **0 transactions / No matching transactions** and the Home review badge disappears. Home then shows **612 saved transactions**, **0 transactions to review**, and a disabled review action while its monthly report still says one included entry needs review. “Recent transactions” begins on **June 6** instead of October 24.

Search, account/category filtering, and sorting share the same page-scoped implementation. Older entries are available through pagination; this is not a permanent 500-entry limit. The defect is presenting page-scoped filtering/counts and page-dependent Home state as ledger-wide behavior.

**Small correction:** Query/filter/sort the whole ledger before pagination. Obtain Home review totals and recent entries independently of the current Transactions page. Show result totals and page ranges consistently.

**Evidence:** [False empty filtered page](evidence/08-review-pagination-false-empty.jpg), [Home contradiction](evidence/09-home-page-scope-contradiction.jpg). `TransactionsView.swift:14` filters and sorts `workspace.transactions`; pagination at line 173 labels the filtered current-page count while enabling Next from the whole-ledger total. `AppWorkspace.swift:197` loads `snapshot(limit: 500, offset: page * 500)`, its review count at line 79 uses that array, and `HomeView.swift:29` uses its first five entries. Paths are under `apps/macos/GroundKeeper/`.

### UX-03 — Refund and direction can contradict each other

**Reproduce:** Edit the **$250 Neighbourhood Café** purchase. Keep **Money out**, change Type to **Refund**, then save.

**Observed:** Save succeeds with no consistency warning or direction adjustment. The table displays **Refund** and **−$250.00** together. The entry was subsequently restored to Purchase.

**Why it matters:** The transaction display signs amounts using direction, while Spending treats refunds as a subtraction using their absolute amount. The contradictory combination is therefore meaningful, not just awkward wording. The exact resulting report total was not separately measured during this edit.

**Small correction:** Enforce consistent type/direction combinations, or explicitly update direction when a type is selected and let the user review that change.

**Evidence:** [Enabled save](evidence/06-refund-money-out-enabled.jpg), [saved contradiction](evidence/07-refund-negative-saved.jpg). `TransactionEditor.swift:25` validates amount/account/category but not type/direction; `Models/Transaction.swift:44` formats by `isDebit`; `GroundKeeperCore/Sources/GroundKeeperCore/SpendingQueries.swift:33` derives refund net from `-abs(amount_minor)`.

### UX-13 — Capture reconciliation hides the facts needed to decide

**Reproduce:** Import a capture matching one of the fictional CSV transactions, assign an account, and review the possible duplicate.

**Observed:** Capture-review rows show merchant, review reason, and card label. They omit the source amount, currency, and date. A possible-duplicate button says **Link to Maple Corner Cafe · Oct 1, 2026**, with no candidate amount/account or source comparison. There is no detail action before **Link** or **Keep as a separate transaction**. The tested duplicate was successfully linked after independently knowing the fixture's facts.

**Small correction:** Display capture and candidate amount/currency/date/account together and make the preserved source evidence available before resolution. This context is also useful when choosing an account for an otherwise valid capture.

**Evidence:** [Capture review and duplicate candidate](evidence/21-duplicate-review-missing-facts.jpg). `Features/Sync/SyncView.swift:59` renders the review row; candidate labels at line 85 include merchant and date only.

### UX-05 — Duplicate account names are indistinguishable

**Reproduce:** Settings → add another **Everyday card · Demo**, CAD, Credit card.

**Observed:** “Account added” succeeds and Settings displays two identical name/CAD rows. No rename/archive/delete control is available there. Account pickers use the same visible name/currency, while the Transactions account filter compares account names and cannot separate these accounts.

**Small correction:** Prevent accidental identical accounts or require a distinguishing label. Provide a way to maintain account labels. Use stable IDs for filtering even when names happen to match.

**Evidence:** [Duplicate account rows](evidence/10-duplicate-accounts.jpg). `Features/Settings/SettingsView.swift` Accounts section; `Features/Transactions/TransactionsView.swift:18` compares `transaction.account == account` and builds picker choices from names.

### UX-11 — Process queue does not explain manual categorization

**Reproduce:** Leave the provider at **Manual categorization**, import the five fictional CSV rows, then click **Process queue (5)**.

**Observed:** Only the count-check timestamp changes. Five entries still await classification; Activity says **0 classification jobs pending**. There is no explanation at the action or direct route to choose a provider/review those entries manually. The same queue action did successfully ingest capture files later, so this finding concerns the unclassified backlog when no provider is configured.

**Small correction:** Distinguish unclassified entries from runnable jobs. Explain the manual-mode state and offer **Review transactions** or **Choose provider** beside the count.

**Evidence:** [Queue after the command](evidence/18-process-queue-no-provider-feedback.jpg).

### UX-07 — Merchant pagination loses the results above the viewport

**Reproduce on the updated layout:** At the default two-column width, expand all six findings. Scroll to the bottom of the five-row Merchants card and click **Next**; the second page contains one merchant.

**Observed:** The merchant card shrinks above the current scroll offset. The viewport now contains a blank left column and comparison content on the right. The requested merchant and its pagination controls are above the viewport, with no visible acknowledgement of the new result. Expanding findings also produces a long imbalance between the column bottoms.

**Small correction:** Keep the merchant result/pagination anchor visible when the page changes. Review the lower-column gap without changing the established card order unnecessarily.

**Evidence:** [Expanded-column gap](evidence/13-expanded-findings-column-gap.jpg), [after Next](evidence/14-merchant-next-results-above-viewport.jpg). `FullInsights/MerchantReportsView.swift` changes local page state without a scroll anchor; `SpendingDashboardLayout.swift` stacks each explicit column independently.

### UX-02 — Merchant drilldown hides the return path

**Reproduce:** With **Filters & reporting preferences** collapsed, click a merchant name in the Merchants report.

**Observed:** The entire dashboard becomes merchant-filtered and returns to the top. A small muted merchant name is the only persistent selection indicator. **Clear filters** is inside the collapsed disclosure, with no Back or removable selection next to the summary. This was observed before and after the layout rebuild.

**Small correction:** Put the clear-filter action next to the active filter summary so the filtered state explains its own exit.

**Evidence:** [Filtered dashboard with hidden clear action](evidence/05-merchant-drilldown-no-clear.jpg). `FullInsights/SpendingReportsView.swift:168` places Clear filters inside the disclosure.

### UX-06 — Report evidence is a dead end for transaction inspection

**Reproduce:** Open a category's transactions or a finding's supporting transactions, then try to inspect/edit a row.

**Observed:** Rows show merchant, day, and amount; double-clicking does not open a transaction. The only row action is **Correct merchant**. Account, category, notes, receipts, and the existing transaction editor are unavailable in this context. Repeated same-merchant purchases cannot be distinguished by account here.

**Small correction:** Connect the row to the existing transaction detail/editor while preserving the return to the report. Include the account needed to identify the purchase.

**Evidence:** [Report evidence sheet](evidence/12-report-drilldown-no-detail.jpg). `FullInsights/ReportEvidence.swift:20` renders `ReportTransactionsSheet` with merchant correction as its only per-row action.

### UX-08 — Review setup restarts a gated flow without an exit

**Reproduce:** Settings → **Review setup assistant…** → Continue to Privacy.

**Observed:** The workspace becomes the full seven-step assistant, with only Back/Continue and no Cancel/Return to app. Privacy initially selects Encrypted despite the demo currently using unencrypted SQLite, and Continue is disabled until a protection choice is explicitly applied. Reapplying the existing unencrypted choice allowed completion; no weaker protection was selected.

**Small correction:** Let review mode close directly and reflect the current protection. Completed setup should be inspectable without applying it again.

**Evidence:** [Privacy step while reviewing setup](evidence/15-review-setup-forces-protection-choice.jpg). `SettingsView.swift:86` resets the setup step. `SetupView.swift:16` gates Privacy on a protection-choice preference; `VaultProtectionView.swift:57` selects encryption by default in onboarding.

### UX-09 — Currency mismatch disables Save without an explanation

**Reproduce:** Add a merchant and valid positive amount. Select a USD account, which sets the currency to USD. Change the amount currency to CAD while retaining that account.

**Observed:** Save transaction becomes disabled. No inline text identifies the account/currency mismatch, although all obvious required fields appear complete. Cancelling this unsaved transaction correctly displayed the discard confirmation.

**Small correction:** Keep currency tied to the account, or explain the mismatch at the currency/account fields and provide a direct correction.

**Evidence:** [Disabled save without reason](evidence/16-currency-mismatch-no-explanation.jpg). `TransactionEditor.swift:27` requires matching account currency; visible validation messages cover amount and Other-category notes only.

### UX-01 — Merchant search retains an editable hidden selection

**Reproduce:** Manage groups → select **Neighbourhood Café 002** → search for `zzzz`.

**Observed:** The list is empty and says **0 names**, while the detail pane still edits the selected café through **Report as** / **Create a group name**. Filtering does not clear or explicitly identify the retained selection. Group confirmation and Undo themselves worked.

**Small correction:** Clear selection when it disappears, or clearly identify that the retained detail is outside the search results.

**Evidence:** [Empty results with live detail](evidence/04-merchant-search-stale-detail.jpg). `FullInsights/MerchantManagement.swift:40` looks up selection in all names rather than the search matches.

### UX-10 — CSV confirmation omits destination and totals

**Reproduce:** Choose `examples/transactions.csv`, select Everyday card · Demo, map `record_id`, then validate.

**Observed:** The final confirmation shows filename, five selected rows, zero invalid rows, and individual CAD amounts. It omits the destination account and selected money-out/money-in/net totals. Checking the account requires Back. The import itself succeeded; its five source records total CAD 78.73 of money out.

**Small correction:** Retain the destination account and selected debit/credit totals in the confirmation summary.

**Evidence:** [Final preview](evidence/17-import-preview-no-account-or-total.jpg). `Features/Sync/ImportPreviewView.swift:47` summarizes row selection/invalid count; the account picker exists only in the mapping state.

## Smaller observed issues

- **P3 — Pluralization:** Merchant/findings/coverage copy includes forms such as “1 findings,” “1 repeats,” “Previous period: 1 purchases,” “Average gap 1 days,” and “1 included entries need review.” Use the same singular handling already present in the primary purchase count.
- **P3 — One-day chart axis:** A one-day Custom report repeats the same Oct 24 label across the horizontal axis. [Screenshot](evidence/02-single-day-chart.jpg). Use a single relevant date label for this range.
- **P3 — Empty-report guidance:** Last year's empty Spending view says pending/unclassified entries are shown in a “coverage note above,” even when no such note is rendered. Make the guidance conditional.
- **P3 — Capture draft cancellation:** Entered `9.99` in the correction form, clicked Cancel, and returned directly to Sync without a discard warning. This differs from the transaction editor's working unsaved-change guard.
- **P3 — Implementation labels in user copy:** Appearance describes “Brass vault · Fraunces headings”; receipt text ends with the raw producer `apple_shortcuts`. These details can be removed or expressed in ordinary product language without losing the visible preference or evidence source.

## Updated Spending layout assessment

The layout rebuild was explicitly included in the audit. [Default updated view](evidence/11-updated-spending-default.jpg) and [wide System appearance](evidence/22-updated-spending-wide-system.jpg) show the new arrangement. The half-width view used a readable single column. No overlapping cards or clipped controls were observed in the tested Spending states. Merchant search text and expanded-findings state survived crossing between the tested single/two-column widths. Hiding and restoring the sidebar also worked.

The merchant pagination/scroll-position problem in UX-07 is specific evidence to address in this arrangement. Large blank column areas are most apparent with expanded findings; the default view alone would not have revealed that state. The earlier popup-while-scrolling report did not recur during repeated scrolling through categories and surrounding cards. This is a bounded regression check, not proof of absence in every state.

## Limits and uncertainty

- Did not download/install models, run actual model/council/XPC inference, enable DuckDuckGo, send transaction text to a Shortcut/cloud provider, or test provider failure/recovery. Named demo instances are not a substitute for the regular app's Keychain and classifier entitlements.
- Viewed vault protection choices but did not create a passphrase, perform encryption conversion, exercise Keychain unlock, or register background processing. Existing unencrypted protection was reapplied only to exit the setup-review flow.
- Did not install Shortcuts or test a physical iPhone, bank notification, locked-phone capture, real iCloud delivery, image receipt/OCR, or attachment retention. Receipt verification used generated text evidence.
- Native chart pointer selection did not produce a selected callout in these Computer attempts. Because target focus/input routing was not independently established for that gesture, this remains unverified rather than a confirmed app defect. Table-mode values and drilldowns were exercised successfully.
- Did not conduct a complete VoiceOver, high-contrast, reduced-motion, localization, or accessibility-size audit. Accessibility labels were used to navigate, but this does not establish screen-reader usability.
- No actual transaction deletion, account removal, capture dismissal, duplicate “keep separate,” card-mapping removal, or Snooze expiration was executed. Those controls were inspected where available; duplicate linking, grouping/undo, finding dismiss/restore, import and account assignment were exercised.
- Native file-picker path-entry attempts were unreliable through Computer; column navigation later completed CSV and folder selection. An early blocked picker required relaunching this chat's demo. This was not classified as an application defect.
- Another agent could be using a different application instance. Focus/activation alone was not treated as proof of an application bug; every recorded defect refers to content/state in the uniquely addressed audit app. No unexpected modal opening during report scrolling was observed.

## Cleanup

Verified after the audit:

- Both exact named demo directories created here are absent: `ux-audit-a6d4d5f7-a1af-4ee1-ba7f-39395aab44d8` and `ux-audit-layout-be40839e-9f9f-4df6-97cb-f6dfa627cea5` under `.local/macos/Demos/`.
- The original audit process had already exited before rebuilding. The updated audit process was terminated and confirmed exited before its bundle directory was removed.
- The three generated capture fixtures and their temporary directory were removed.
- The other agent's `spending-grid` demo and the pre-existing shared-build processes remained running. The shared Debug app remained present. No source files or pre-existing app copies were deleted by this audit.

Validation for this documentation-only change: launcher build success, observed Computer interactions, source corroboration for the main state defects, and evidence/link checks. No automated test suite was run.

**Highest-impact systemic correction:** make transaction queries, filtered result counts, Home review totals, and Home recency independent of the currently loaded 500-entry page (UX-04).
