# First-launch setup and vault protection

GroundKeeper’s native setup assistant covers features, vault protection,
optional local models, iCloud Drive, iPhone Shortcuts, an account, and a final
review. Progress and choices survive relaunch. Existing ledgers are preserved;
an older installation sees setup once after upgrading. Review the assistant
again in Settings. Automatic processing pauses while setup is visible.

## Storage and unlock

The live vault stays in the app’s local Application Support directory.
SQLCipher 4.19.0 is the only linked SQLite engine. Without a key it produces an
ordinary SQLite file; with a passphrase it encrypts the database and WAL.
The app verifies SQLCipher availability before opening the schema.

Choose a passphrase of at least 12 characters. Encrypted vaults open to a locked
screen. Settings offers Lock vault, change passphrase, and conversion back to
unencrypted storage. Changing protection on an encrypted vault requires the
current passphrase. The passphrase is never written to preferences or logs.

Protection changes export into a sibling file under the exclusive vault owner
lock, validate the new database, checkpoint WAL, sync the completed copy, and
atomically replace the original. Both schemas and records are preserved. The
file header determines encryption mode; there is no separate mode flag that
can become inconsistent after interruption. Key changes use the same verified
replacement path. Conversion does not erase earlier backups or filesystem
snapshots, and no recovery/reset service exists.

Convenience unlock is optional. In provisioned builds, a device-local Keychain
item stores the passphrase with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
and `.userPresence`. Touch ID or the Mac password authorizes retrieval. It is
not a WebAuthn passkey and does not require a GroundKeeper account or backend.
The passphrase remains the recovery credential. Keychain enrollment failure
leaves a working encrypted vault and reports that passphrase unlock is needed.

Apple development builds use `GroundKeeper.Keychain.entitlements`; the launcher
selects this when local signing is configured. Xcode builds can set
`GK_APP_ENTITLEMENTS = GroundKeeper.Keychain.entitlements` in the local signing
configuration. Free ad hoc releases use `GroundKeeper.AdHoc.entitlements`, hide convenience
unlock, and retain passphrase encryption. Their SQLCipher framework requires a
library-validation exception because ad hoc signatures have no Team ID.
Provisioned builds re-sign SQLCipher with the app identity and retain library
validation. No development team is hardcoded.

Encrypted vaults never unlock in the launch agent. Enabling encryption changes
background mode to processing while the app is open. Quitting or explicitly
locking closes the database and stops processing. This version does not add a
screen-lock or idle timer.

## Models and Apple Intelligence

Qwen and Laya are independently optional. Install either or both in the
assistant or Settings, then select an installed package to activate it.
The catalog comes from `release/models.json` and pins release asset sizes,
SHA-256 hashes, and package manifests. Installation verifies streamed parts,
extracts only the pinned archives into staging, and publishes the completed
package atomically. The worker independently verifies package files before
loading. Models and license notices stay in local Application Support.

Downloads support cancellation and retry. A process lock prevents concurrent
installers, and the next installation removes abandoned staging directories.
Extraction has a five-minute deadline. Existing installed versions are never
overwritten. A complete multi-gigabyte download was not repeated for this change.

Apple Intelligence Cloud needs no Qwen/Laya download. Install the bundled
`GK Categorize Cloud` Shortcut, inspect Use Model → Cloud, enable Broad World
Knowledge, choose Text output and disable Follow Up. Then explicitly activate
that provider. Only description, direction and currency are sent. Device
compatibility, Apple Intelligence availability, and usage limits apply. Every
suggestion requires review; providers never fall back to cloud automatically.
Manual categorization remains available throughout.

## iCloud and iPhone

The standard-folder button requests access to iCloud Drive through the system
picker, then creates `Shortcuts/Groundkeeper/inbox`. The custom-folder button
connects the exact selected directory. Set the same destination in the iPhone
writer. Source capture JSON remains in iCloud after successful import; local
SQLCipher encryption does not encrypt those originals.

Install the shared writer before the Wallet adapter using Shortcuts iCloud sync
or AirDrop. The app bundles signed, device-independent installers and a
step-by-step phone guide. Personal automations, card selections, folder grants,
and actual transaction-trigger testing must be completed on the phone. The CIBC
adapter is experimental and opt-in. See the [Shortcuts guide](../shortcuts/README.md).

## Verification

Validated locally: 17 Swift core tests, 14 focused Python tests, provisioned Debug
and ad hoc Release builds, and app setup, ledger, queue, and classifier connection
smoke checks. The full assistant was walked through in the disposable preview.

- Core Swift tests cover data-preserving encryption/plaintext round trips,
  wrong-key rejection, current-key verification, key rotation, exclusive
  ownership, and corrupt/truncated/oversized model archive parts.
- `--setup-preview --setup-smoke` uses disposable storage and preferences to
  exercise the app’s lock/unlock/rotation lifecycle. It checks protected Keychain
  item creation/removal in a provisioned build and checks bundled installers.
  Actual Touch ID/password authentication requires an interactive user check.
- `--setup-preview` opens the assistant with isolated preferences and a temporary
  vault; `--setup-preview-step N` starts at a zero-based step for layout checks.
- Shortcut source tests check variable references and absence of personal
  folder/trigger permissions. Signed import was checked on Mac. The synthetic
  CLI capture check timed out; output typing and phone delivery remain device
  verification items.

Primary implementation references: [SQLCipher integration](https://www.zetetic.net/sqlcipher/sqlcipher-apple-community/),
[SQLCipher export API](https://www.zetetic.net/sqlcipher/sqlcipher-api/),
[Apple Keychain user presence](https://developer.apple.com/documentation/localauthentication/accessing-keychain-items-with-face-id-or-touch-id),
and [Apple Intelligence in Shortcuts](https://support.apple.com/en-gb/guide/iphone/iph78c41eaf8/ios).
