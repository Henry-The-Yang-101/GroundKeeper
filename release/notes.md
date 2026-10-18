Apple silicon macOS prerelease. Requires macOS 26.2 or later.

Download `GroundKeeper-arm64.dmg`, open it, and drag the app into Applications.
The app is ad hoc-signed, not notarized. macOS may require **Privacy & Security >
Open Anyway** on first launch. Python and the inference libraries are included. Manual entry and CSV import
work without a model.

For local classification, download all three model archive parts,
`MODEL_SHA256SUMS.txt`, and `Install Models.command` into one folder. Run
`bash './Install Models.command'` there, then choose the installed Qwen or Laya
folder in Settings. Read `INSTALL.md` for the full procedure and
`MODEL-NOTICES.txt` for upstream attribution.

Model versions: `qwen-delaware-v1-step5872` and `laya-epoch3`.
Review every category suggestion. GPU inference and real iPhone capture still
need testing on the target device; the hosted release checks cover the core
tests, temporary ledger, signatures, and the XPC/Python connection.

`SHORTCUTS.md` explains the included Shortcut exports and capture setup.
Storage currently uses unencrypted SQLite. Backup and recovery are planned.

Closed-app background processing is disabled in this free release after macOS
rejected an ad hoc update. Automatic processing while the app stays open and
manual processing are available. Closing the window does not quit GroundKeeper.
