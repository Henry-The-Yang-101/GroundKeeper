# GroundKeeper macOS application

The SwiftUI app now uses **ordinary SQLite** in local Application Support.
Capture ingestion, CSV import, reconciliation, transaction editing and local
classification are connected. Analytics and encryption are deferred.

## Build and launch

Requires Xcode and macOS 26.2+ on Apple silicon, matching the bundled MLX runtime.
With the pinned Python runtime already staged:

```sh
./apps/macos/run.sh
```

The app is built at
`.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app`.
The local Swift package `GroundKeeperCore` uses the system SQLite library and
has no external package dependency. The XPC service embeds the existing pinned
Python/MLX/PyTorch runtime; see [classifier setup](../../contracts/classifier/README.md).

## First use

1. In Settings, add your real accounts and their currencies. There are no
   invented default financial accounts or sample transactions in the live DB.
2. Choose a verified local model package in Settings to enable classification.
3. In Sync, connect the existing iCloud `GroundKeeper` folder or its `inbox`.
4. Confirm captured card labels against accounts in Sync's review list. Import
   CSV files with explicit date, amount/sign and column mapping.

All classifier suggestions require review. Editing confirms an assignment and
protects it from late classifier replies. Unknown notification formats can be
corrected without overwriting the original capture. Possible duplicates can be
linked or retained separately. Source files remain in iCloud; persisted delivery
identities prevent replay.

## Queue processing modes

Settings → Queue processing offers three persisted choices:

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

**Local development signing limitation:** on this Mac, launchd accepted the first
ad-hoc build but rejected the rebuilt service with `OS_REASON_CODESIGNING`.
No Apple signing identity is installed. The app checks the agent heartbeat and
reports a registered-but-unresponsive service rather than treating registration
as proof of execution. Use an Apple Development or Developer ID signing identity
for dependable background service launches and updates. App-open and manual
processing work with the current build. Do not reset system security settings or
the global background-task registry to work around this development limitation.

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

Keyboard shortcuts: ⌘N adds a transaction, ⌘F opens transaction search, ⌘,
opens Settings, and ⌘1–⌘4 selects a navigation tab.

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

Queue verification: 12 core tests pass. The Debug queue smoke checks a 205-file
inventory/drain, manual-mode gating, restart deduplication, automatic processing,
retry backoff and CSV classification gating against temporary fictional data.
A direct headless-agent probe verified database ownership after quitting and
handoff on reopening. Rebuilt launchd execution remains blocked by the local
ad-hoc signing limitation above; it is not claimed as a passed service test.
