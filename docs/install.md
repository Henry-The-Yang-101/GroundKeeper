# Install GroundKeeper

Use an Apple silicon Mac running macOS 26.2 or later. The release app includes
CPython, the Python worker, MLX, and PyTorch. You do not need Xcode, Python, or uv
to use it.

## Install the app

1. Open the project's [Releases page](https://github.com/Henry-The-Yang-101/GroundKeeper/releases)
   and choose a `GroundKeeper build` prerelease. The `models-*` release only
   stores model assets for the build workflow.
2. Download `GroundKeeper-arm64.dmg`, open it, and drag GroundKeeper into
   Applications. Eject the disk image and open the installed app.
3. Follow the setup assistant to choose protection, categorization, capture, and
   an account. Try a fictional manual transaction or CSV import first.

The app is ad hoc-signed and is not notarized by Apple. macOS may block its
first launch because the developer cannot be verified. If you trust the release,
attempt to open the app, then open **System Settings > Privacy & Security** and
choose **Open Anyway** for GroundKeeper. Follow the confirmation prompts.
See [Apple's instructions](https://support.apple.com/en-ie/102445).
Managed Macs may prevent this exception.

If no app release is listed yet, use the repository's
[source build guide](https://github.com/Henry-The-Yang-101/GroundKeeper/blob/main/docs/setup.md).

## Install the local models

The setup assistant can download and install Qwen, Laya, or both directly.
Choose the installed model to activate it. You can skip downloads and use Apple
Private Cloud Compute (macOS 27 and an approved PCC build) or manual categorization. Allow at least 9 GB of free space
for both installations.

For manual installation, models are separate downloads on the same release. The app works for manual
entry and CSV import without them. Download these files into one folder:

- Every `GroundKeeper-*.tar.gz.part*` file, including both Qwen parts.
- `MODEL_SHA256SUMS.txt`.
- `Install Models.command`.

The current packages take about 3.7 GB to download and 4.1 GB after extraction.
Allow at least 9 GB of free space for both the archives and installed models,
plus space for the app.

In Terminal, change to that download folder and run:

```sh
bash './Install Models.command'
```

The script checks every archive's SHA-256 checksum before extracting. It opens
the installed directory under
`~/Library/Application Support/GroundKeeper/Models/models-20261018/`.
In **Settings > Categorization > Choose local model package**, choose either
the `qwen-delaware` or `laya` directory. GroundKeeper verifies the package again
before loading it. Keep that folder in place after selecting it.

The packaged versions are `qwen-delaware-v1-step5872` and `laya-epoch3`.
These are experimental classifiers. Review their suggestions; merchant text
alone cannot reliably identify every purchase at mixed retailers.

The installer refuses to overwrite an existing model directory. If extraction
was interrupted, move that version's directory aside before retrying. Keep
`MODEL-NOTICES.txt` with your model downloads.

## Shortcuts and background processing

The disk image's **Shortcuts** folder and each release include the available
`.shortcut` files and a setup guide. Start with `README.md` in that folder, or
`SHORTCUTS.md` in the release downloads. Capture through iCloud and optional
Apple Intelligence classification have separate setup steps.

The free release supports automatic processing while GroundKeeper stays open,
or manual **Process queue** runs. Closing its window does not quit the app.
Closed-app background processing is disabled: a replacement ad hoc build was
rejected by macOS launch constraints during testing. No Apple account is needed
for the supported modes.

After replacing the app, reconnect model or capture folders if macOS no longer
accepts their saved permissions. Quit the previous version before replacing it.

The ledger supports unencrypted SQLite or passphrase-protected SQLCipher in
the app’s sandbox container. Touch ID / Mac password convenience unlock needs
a provisioned Keychain identity and is unavailable in the free ad hoc build.
Encrypted vaults process while open and unlocked, or manually. See
[setup and vault protection](onboarding.md). Backup and recovery tooling is still planned.

Native Apple categorization requires an Apple-approved PCC entitlement, which
the free ad hoc release does not carry. See [native PCC availability](apple-private-cloud-compute.md).
