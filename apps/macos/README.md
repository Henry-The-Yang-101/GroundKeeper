# GroundKeeper macOS interface

A native SwiftUI frontend for Home, Full insights, Sync, and Settings. This is
an **interface preview with fictional data**, not a connected finance app.
Transaction changes live in memory and disappear when the app quits. Only the
appearance preference is saved in UserDefaults.

## Build and launch

Requires Xcode 16 or later with its command-line tools selected. Deployment
target: macOS 26.2+ on Apple silicon, matching the pinned MLX native runtime.
Verified locally with Xcode 27. The earlier UI-only preview targeted macOS 14.

From the repository root:

```sh
./apps/macos/run.sh
```

Build output goes to the ignored `.local/macos/DerivedData/` directory. Open
`GroundKeeper.xcodeproj` to use Xcode or SwiftUI previews. Local builds use ad hoc
signing and the bundle identifier `com.groundkeeper.macos`.

The window defaults to 1140 × 800, with a 760 × 560 minimum. macOS may restore
its previous size. The native sidebar can be resized or hidden. Standard window
controls, tiling, full screen, menus, keyboard focus, and scrolling are retained.

## What you can try

- **Home:** fixed spending example, review count, and recent transactions. Open
  a transaction to edit it or jump into the review queue.
- **Full insights / Spending:** Swift Charts bars with exact hover values, a
  selectable text table alternative, and ranked category amounts. Report values
  are fixed fixtures, independent of edits to sample transactions.
- **Full insights / Transactions:** search descriptions, notes, categories, or
  types; filter by account, category, or review status; sort by date, merchant,
  or amount. Select and edit, double-click, or use the context menu. Deletion
  requires confirmation.
- **Transaction editor:** merchant, amount, currency, date, account, type,
  category, review status, source, and notes. Amounts must be positive with at
  most two decimal places, without thousands separators, for the four supported preview currencies. Other
  expenses require a note. Uncategorized purchases/refunds stay in review.
  Canceling a changed draft asks before discarding it.
- **Planning:** fixed budget and savings-goal examples, plus a balance-data
  empty state. Creating budgets, funding goals, and recording balances are not
  connected.
- **Sync:** disconnected capture status, setup explanation, activity empty state,
  and a two-step CSV mapping/review walkthrough. The walkthrough uses fixtures;
  it does not read files, interpret mappings, validate rows, or import anything.
- **Settings:** System/Light/Dark appearance, restore/clear sample transactions,
  and disclosure groups explaining future provider/account configuration.
  Security and provider statuses explicitly show that they are not connected.

| Shortcut | Action |
| --- | --- |
| ⌘1–⌘4 | Home, Full insights, Sync, Settings |
| ⌘N | Add a sample transaction |
| ⌘F | Open and focus transaction search |
| ⌘E | Edit the selected visible transaction |
| ⌘, | Settings |
| Return / Escape | Save or cancel a transaction sheet |

Colors use native semantic surfaces and a light/dark accent asset. Controls
retain system focus indicators and accessibility labels. Review states include
text and symbols; charts expose exact amounts and a table alternative. No custom
motion or AppKit window-control positioning is used.

## Code organization

```text
GroundKeeper/
  App/                      App scene, menu commands, native split navigation
  Models/                   Presentation types and spending-category vocabulary
  Preview/
    PreviewWorkspace.swift  Observable, disposable transaction/navigation state
    SampleData.swift        Fictional transactions and fixed report fixtures
  Features/
    Home/                   Overview
    FullInsights/           Report chart, categories, planning examples
    Transactions/           Searchable table, rows, and draft editor
    Sync/                   Disconnected state and CSV walkthrough
    Settings/               Appearance and preview controls
    Shared/                 Small reusable layout and presentation components
  Resources/                Adaptive accent asset
  Services/                 Async XPC classifier client and smoke runner
```

The synchronized Xcode source folder picks up new Swift files automatically.
The app has no third-party dependencies. `PreviewWorkspace` is deliberately not
an eventual storage or finance service. Keep future database, reconciliation,
classification, reporting, and file access behind separate service contracts.

## Integration boundaries

No SQLite/SQLCipher, iCloud access, network requests, background jobs, insights
calculations, encryption, Touch ID, or backups are connected. Reports and
planning do not derive from edited transactions.
Settings now includes explicit local classifier diagnostics using the bundled
XPC/Python service: check Metal GPU support, select a verified data-only model
package, classify fictional sample text and release the model. This does not
automatically categorize or persist the sample workspace. See the
[classifier bridge guide](../../contracts/classifier/README.md) for build,
runtime pins, model export, protocol, signing and verification details.
The review count and list filtering/sorting are presentation state only.

Categories follow `../../TRANSACTION_CATEGORIES.md`: the 18 named spending
categories, separate Uncategorized/Other fallbacks, and an independent review
status. Transaction types remain separate from categories. Editing a sample
transaction never creates a merchant rule.

The existing Python experiments, captures, and training artifacts are untouched.
See `../../PLAN.md` for the intended product and service contracts still needed.

## Validation

Debug and Release builds are checked with `xcodebuild`. The interface is also
smoke-tested in the running app: light/dark appearance, compact window layout,
keyboard navigation, sample transaction creation/editing and input validation,
search/review filtering and no-results recovery, draft-discard confirmation,
chart table values, and the CSV walkthrough. This is UI validation, not evidence
that the planned backend features work. VoiceOver narration and all macOS
accessibility preference combinations have not been exhaustively tested.
