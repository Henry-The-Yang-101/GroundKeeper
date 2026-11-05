# Automatic capture validation — 2026-11-05

Implementation: `bcd839b`.

The signed `GroundKeeper Capture Automatically` export was imported through
Shortcuts. Its single Save File action was configured for the existing iCloud
Drive `Shortcuts/GroundKeeper/inbox` folder, with Ask Where to Save and overwrite
both off. The existing Wallet and CIBC adapters were edited in place to call
this writer with their Dictionary input, preserving their native trigger bindings.
iPhone Mirroring confirmed both phone automations enabled and both Run Shortcut
targets synced to the new writer.

## Native execution

All inputs were fictional, included `is_test: true`, and used distinct
`wallet_priority_group` values. A separate diagnostic shortcut displayed the
writer's return value; this display action is absent from the installed writer.

| Device | Case | Observed result |
| --- | --- | --- |
| Mac | Wallet | Returned saved event; JSON appeared in the configured inbox. |
| Mac | Matching CIBC immediately after saved Wallet | Completed without an event or second file. |
| Mac | Independent CIBC | Returned saved event after the grace period; JSON appeared in the inbox. |
| Mac | Cancel Wallet Save File, then matching CIBC | In an isolated duplicate with Ask Where to Save enabled, canceling Wallet did not suppress CIBC: CIBC reached Save File. Both test dialogs were canceled. |
| iPhone | Wallet | Returned saved event at 02:00:52 local time; corresponding JSON synced to the Mac inbox. |
| iPhone | Independent CIBC | Returned saved event at 02:05:10 local time; corresponding JSON synced to the Mac inbox. |

The production writer's Wallet/CIBC runs required no receipt, note, location, or
save-folder input. The four saved fictional JSON files were moved to Trash after
inspection. The cancellation probe never wrote a capture file.

## Automated verification and limits

The capture-source, Apple Shortcuts contract, and database-schema test selection
passed 50 tests. Ruff passed. An unsigned Debug app build succeeded using isolated
DerivedData.

No purchase was made and no real bank push notification was generated. These
checks verify installed writer execution, iCloud file delivery, duplicate/cancel
behavior on Mac, and phone configuration; they do not establish a new physical
Wallet tap or background CIBC notification delivery. The exact action responsible
for historical timeout messages remains unproven. The old menu-before-save path
and early Wallet marker suppression were reproduced separately during diagnosis.
