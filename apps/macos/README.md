# GroundKeeper macOS application

The SwiftUI app offers ordinary SQLite or SQLCipher encryption in local Application Support.
Capture ingestion, CSV import, reconciliation, transaction editing, and the
classifier queue are connected. First launch walks through protection, optional models,
iCloud capture and phone setup. Home and Spending now show local spending reports,
category breakdowns, period comparisons, and calculated findings. See
[spending reports](../../docs/spending-reports.md) and [setup and protection](../../docs/onboarding.md).

## Brass vault interface

The app uses Fraunces for headings and the macOS system font for controls,
transaction text, and tabular amounts. Fraunces is bundled for offline use with
its SIL Open Font License in `GroundKeeper/Resources/Fonts`. The shared palette
in `VaultTheme.swift` and the asset catalog supports System, Light, Dark, and
increased contrast. Light mode uses parchment and bronze; dark mode uses
graphite and pale brass.

Button presses, row hover states, changing counts, setup steps, and successful
saves have short, scoped feedback animations. They honor macOS Reduce Motion.
Native tables, menus, keyboard shortcuts, sheets, and focus handling remain in
place.

For a populated UI walkthrough after building Debug, quit that build and run:

```sh
open -n .local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app \
  --args --setup-preview --ui-preview
```

Both flags are required. This Debug-only fixture uses a fresh temporary vault
and separate preferences, seeds five fictional transactions, selects manual
processing, and does not connect a capture folder or provider. Ordinary launches
continue to use the real vault. To inspect an empty onboarding step instead, use
`--setup-preview --setup-preview-step 0` (steps 0–6).

Visual verification should cover both appearances, minimum-width windows,
sidebar visibility, long merchant names, review filtering, empty search results,
editing and save feedback, imports, receipts, and Settings sheets.
For appearance regression checks, select Dark → System while macOS is light,
then Light → System while macOS is dark. Content, native controls, and newly
opened sheets should all return to the current system appearance without a
relaunch. System mode uses AppKit appearance inheritance so later macOS
appearance changes also propagate.

## Build and launch

Requires Xcode and macOS 26.2+ on Apple silicon, matching the bundled MLX runtime.
Follow the [setup guide](../../docs/setup.md) to install both pinned Python
environments on a fresh checkout. Then build and launch with:

```sh
./apps/macos/run.sh
```

The app is built at
`.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app`.
The local Swift package `GroundKeeperCore` pins Zetetic’s official SQLCipher
4.19.0 package. It also opens ordinary SQLite when no passphrase is supplied. The XPC service embeds the existing pinned
Python/MLX/PyTorch runtime; see [classifier setup](../../contracts/classifier/README.md).

## Configure Apple development signing

This is optional. The [free release build](../../docs/releases.md#local-release-build)
uses ad hoc signing and requires no Apple account.

1. Open Xcode → Settings → Apple Accounts and sign in to your Apple Account.
2. Select your team → Manage Certificates. Create an **Apple Development**
   certificate if there is not already a usable one on this Mac. Keep its private
   key in Keychain; do not export or commit it.
3. Copy `apps/macos/Signing.xcconfig.example` to
   `.local/macos/Signing.xcconfig` and replace `YOUR_TEAM_ID` with your team ID.
4. Rebuild with `./apps/macos/run.sh`, or open the Xcode project and build there.
   The launcher allows Xcode to update development provisioning when the private
   signing configuration is present.

Both targets inherit `Signing.xcconfig`. Without the private override, builds
remain ad-hoc signed. With it, the app and classifier use automatic Apple
Development signing with the same team. The Python embedding step also signs
native libraries with Xcode's resolved identity and invalidates its embedding
cache when that identity changes. The background agent is the app executable
and therefore shares its identity. Bundle identifiers and the SQLite location
are preserved.

This configures development on your Mac. The public release workflow uses ad hoc
signing and does not notarize the app. Successful registration alone does not
prove background execution; check the helper heartbeat.

## First use

1. In Settings, add an account and its currency. The app starts with an empty
   database. The [fictional CSV walkthrough](../../examples/README.md) provides
   a first-run exercise.
2. Add transactions manually or import a CSV with explicit date, amount/sign,
   and column mapping. A classifier is optional for these workflows.
3. Choose a verified local model package or explicitly enable an Apple
   Intelligence Shortcut in Settings to try categorization.
4. If you already use the capture Shortcut, connect the iCloud `GroundKeeper`
   folder or its `inbox` from Sync. Confirm captured card labels against accounts
   in Sync's review list. The iPhone capture export is not included in this repo.

All classifier suggestions require review. Editing confirms an assignment and
protects it from late classifier replies. Unknown notification formats can be
corrected without overwriting the original capture. Possible duplicates can be
linked or retained separately. Source files remain in iCloud; persisted delivery
identities prevent replay.

## Queue processing modes

Source builds offer three persisted queue choices. The free ad hoc release
offers while-open and manual processing; closed-app background mode is disabled
after a replacement-build launch failure.

- **Automatically in the background:** a sandboxed `SMAppService` launch agent
  processes work after the UI quits and at login, while the Mac is awake. macOS
  may require enabling GroundKeeper in Login Items & Extensions.
- **Only while GroundKeeper is open** (default): automatic processing every
  15 seconds until the app quits. Closing or minimizing its window does not quit it.
- **Only when I click Process queue:** counting remains automatic, but capture
  ingestion and classifier inference require an explicit button click. Connecting
  a folder, importing a CSV, retrying failures or resolving a review does not
  implicitly run the classifier in this mode.

The **Process queue (N)** button appears in both Settings and Sync. Its count is
pending capture files plus pending/unclassified transactions, including work
awaiting model selection or retry deadlines. Failures and review items are
separate. Counts refresh every 15 seconds and on demand, without importing files,
starting downloads or loading a model. Unavailable counts are labeled explicitly.
One click processes the existing backlog in bounded capture batches, respecting
persisted backoff. Files still downloading or waiting for retry remain pending.

The helper uses the same executable, sandbox container, database and bookmarks
as the UI, through a headless entry point that does not register an application
window. A foreground lease requests handoff; the existing database ownership
lock prevents concurrent writers. Handoff cancels in-flight inference without
consuming a retry and releases the Python worker before closing the database.
Switching away from background mode unregisters the launch agent.

An initial ad hoc background diagnostic succeeded, but a replacement build was
killed by macOS with `Launch Constraint Violation`. The free release disables
closed-app background mode and converts a saved background preference to
while-open processing. Its headless production entry point exits immediately.
Closing the app window still leaves while-open processing active; quitting stops it.

Source builds retain background support and heartbeat checks. A failed enable
attempt restores the prior mode. The current service uses
`com.groundkeeper.macos.queue-processing`; enabling it unregisters the legacy
`com.groundkeeper.macos.queue` service. The legacy plist is retained for that
supported cleanup. No system-wide registry or security setting is reset.
See [release verification](../../docs/releases.md#local-verification-and-background-limits)
for the diagnostic procedure and its limits.

The live database is at
`~/Library/Containers/com.groundkeeper.macos/Data/Library/Application Support/GroundKeeper/vault.sqlite`.
It is never synced as a live SQLite file. See the
[schema audit and implementation](../../contracts/database/IMPLEMENTATION.md)
for migrations, retries, matching rules and current limits.

## UI

Home shows recent saved transactions and setup status. Transactions supports
editing, soft deletion, page-local filters/search/sorting and 500-row pagination.
Sync contains imports, capture review and queue activity. Settings contains
accounts, queue processing preferences and local model selection. The earlier charts/planning prototypes
remain source fixtures but are not exposed as live reports.

In Sync → Review captures, choose an account and **Use for this transaction**.
Optionally check **Remember this card for future transactions** to save the exact
Wallet card or bank card description for that source. The option starts unchecked
and is also available when correcting capture details. Dismissing the review
leaves it unmapped. Settings → Card mappings lets you change the account or remove
a saved mapping. These changes affect future imports, including delayed captures;
saved transactions and other reviews retain their existing account choices.

Keyboard shortcuts: ⌘N adds a transaction, ⌘F opens transaction search, ⌘,
opens Settings, and ⌘1 through ⌘4 select a navigation tab.

## Verification

```sh
swift test --package-path apps/macos/GroundKeeperCore --scratch-path .local/macos/CoreBuild
.venv/bin/python -m pytest tests/test_database_schema.py tests/test_worker.py -q
.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app/Contents/MacOS/GroundKeeper --ledger-smoke
.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app/Contents/MacOS/GroundKeeper --queue-smoke
```

For a synthetic database → real XPC classifier → persisted assignment check,
append `--ledger-model-picker /path/to/model-package`. The picker grants the
service access to the selected model. Smoke mode uses a separate temporary
fictional database, never the primary database. Use a whole-process timeout
when automating smoke checks.

Queue verification recorded on 2026-10-17: 12 core tests passed. The Debug queue
smoke checked a 205-file inventory/drain, manual-mode gating, restart deduplication, automatic processing,
retry backoff and CSV classification gating against temporary fictional data.
The Apple-signed build also verified real launchd startup, database ownership after
quitting, and handoff on reopening. A subsequent signed rebuild and helper
re-registration passed as well. The signed XPC smoke test passed protocol,
cancellation, MLX GPU and PyTorch MPS checks. Login/reboot behavior has not been
tested by logging out or restarting this Mac.

## Classifier providers

Settings → Categorization lets you choose a Qwen or Laya data-only package, or
explicitly enable an Apple Intelligence Shortcut by name. The saved provider is
restored by foreground and background queue processing. Manual mode still waits
for Process queue. No provider automatically falls back to another.

The selected Qwen continuation from 2026-10-18 is packaged locally at
`.local/macos/models/qwen-delaware` (`qwen-delaware-v1-step5872`, v2 prompt).
The prior `.local/macos/models/qwen` package remains available for rollback;
Laya is `.local/macos/models/laya`. These ignored model artifacts are not included
in a fresh clone. To export the continuation when those inputs are available:

```sh
.venv/bin/python -m scripts.export_selected_qwen \
  .local/macos/models/qwen .local/finetune/delaware-v1 \
  .local/macos/models/qwen-delaware \
  --training-config experiments/finetune/delaware-v1/training_config.json
```

The destination must not exist. Export checks the selected adapter hash and base
weight hash, clones the base files, and verifies the complete output manifest.
Training labels were weak labels; every app prediction continues to need review.

The Shortcut receives only description, direction and currency. Its Use Model
action determines the actual execution service; the app cannot attest which model
a user-edited Shortcut calls. The database conservatively records this provider
as cloud-capable (`execution=cloud`), with identity derived from the Shortcut name,
policy and connector version, not a hash of Apple's model or Shortcut contents.
Re-enable the provider after renaming a Shortcut. Apple quota/configuration errors
leave jobs failed for explicit Retry failed; timeouts use the existing bounded
retry policy. Cancellation kills/reaps the CLI child and releases the queue job;
an action already dispatched inside Shortcuts may continue in Apple's service.
Temporary input/output files are removed on normal completion, error or cancellation.

Verification on this Mac: signed XPC reached `GK Categorize Cloud`, which returned
Apple's model usage-limit error. A successful Apple Intelligence prediction must
be checked after that quota resets. No sandbox entitlements were expanded.
