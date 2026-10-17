# GroundKeeper macOS application

The SwiftUI app now uses **ordinary SQLite** in local Application Support.
Capture ingestion, CSV import, reconciliation, transaction editing and local
classification are connected. Analytics, encryption and unattended execution
while the app is closed are deferred.

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
identities prevent replay. The app checks the folder every 15 seconds while open.

The live database is at
`~/Library/Containers/com.groundkeeper.macos/Data/Library/Application Support/GroundKeeper/vault.sqlite`.
It is never synced as a live SQLite file. See the
[schema audit and implementation](../../contracts/database/IMPLEMENTATION.md)
for migrations, retries, matching rules and current limits.

## UI

Home shows recent saved transactions and setup status. Transactions supports
editing, soft deletion, page-local filters/search/sorting and 500-row pagination.
Sync contains imports, capture review and queue activity. Settings contains
accounts and local model selection. The earlier charts/planning prototypes
remain source fixtures but are not exposed as live reports.

Keyboard shortcuts: ⌘N adds a transaction, ⌘F opens transaction search, ⌘,
opens Settings, and ⌘1–⌘4 selects a navigation tab.

## Verification

```sh
swift test --package-path apps/macos/GroundKeeperCore --scratch-path .local/macos/CoreBuild
.venv/bin/python -m pytest tests/test_database_schema.py tests/test_worker.py -q
.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app/Contents/MacOS/GroundKeeper --ledger-smoke
```

For a synthetic database → real XPC classifier → persisted assignment check,
append `--ledger-model-picker /path/to/model-package`. The picker grants the
service access to the selected model. Smoke mode uses a separate temporary
fictional database, never the primary database. Use a whole-process timeout
when automating smoke checks.
