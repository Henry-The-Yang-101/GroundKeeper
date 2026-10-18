# Release maintenance

Every push to `main` starts [release.yml](../.github/workflows/release.yml).
It tests the Python and Swift code, builds an arm64 Release app with the pinned
Python runtime, signs it with your Developer ID, runs the ledger smoke check,
and notarizes a drag-to-Applications disk image. A second job verifies the
pinned model archives and publishes the app, both models, Shortcuts, installation
instructions, and checksums together as a GitHub prerelease.

Tags use `build-<run number>-<commit>-<attempt>`. Failed tests, missing assets,
invalid signatures, or rejected notarization stop publication. Uploads first go
to a draft release, so an interrupted upload is not presented as a complete
download. A failed publish job may leave a draft to remove or inspect.

## One-time signing setup

Public macOS distribution needs a **Developer ID Application** certificate with
its private key and an Apple Developer Program team. An **Apple Development**
certificate is for development and does not satisfy this workflow. See
[Apple's Developer ID guide](https://developer.apple.com/developer-id/) and
[GitHub's certificate setup guide](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

In Keychain Access, export your Developer ID Application certificate together
with its private key as a password-protected `.p12`. Encode the file as base64
and add it directly to GitHub Secrets. Do not commit the certificate, export
password, or Apple credentials.

In the repository's **Settings > Secrets and variables > Actions**, configure:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application `.p12`, including its private key |
| Secret | `MACOS_CERTIFICATE_PASSWORD` | Password chosen when exporting that `.p12` |
| Secret | `APPLE_ID` | Apple account email authorized for the team |
| Secret | `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password used by `notarytool` |
| Variable | `APPLE_TEAM_ID` | The certificate's ten-character team ID |

The workflow imports the identity into a temporary runner keychain and deletes
it during cleanup. Signing credentials are used only in the build job, which
has read-only repository permissions. The publish job uses GitHub's automatic
token with `contents: write`; no personal GitHub token is required.

The workflow uses GitHub's [`xcode-27` arm64 image](https://github.com/actions/runner-images)
to match the local Xcode toolchain. Confirm that Actions and this runner are
available for the repository. The release job excludes the single MLX logits
test that needs Metal; run the full Python suite locally on Apple silicon.
Hosted CI does not validate GPU inference, real iPhone capture, or login/reboot
behavior.

## Upload the model assets once

GitHub runners cannot read local training checkpoints. The model catalog in
[`release/models.json`](../release/models.json) pins the two selected packages:

| Package | Model ID |
| --- | --- |
| Qwen | `qwen-delaware-v1-step5872` |
| Laya | `laya-epoch3` |

Their archives have been prepared locally in
`.local/releases/models-20261018/`. Qwen is split across two parts to stay below
[GitHub's per-asset size limit](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).
The catalog records each part's size and SHA-256 hash. No training or evaluation
dataset is included.

After committing and pushing the release tooling, use an authenticated
[GitHub CLI](https://cli.github.com/) to create the seed release from the repo:

```sh
gh release create models-20261018 \
  --target "$(git rev-parse HEAD)" \
  --title 'GroundKeeper model packages 2026-10-18' \
  --notes-file release/model-notes.md \
  --prerelease --latest=false --draft \
  .local/releases/models-20261018/*.part* \
  release/MODEL-NOTICES.txt
gh release edit models-20261018 --draft=false
```

You can also create that tag through GitHub's Releases page and upload the
same three archive parts plus the notices. Do not upload the model directories
to Git. Keep the seed release and its files unchanged: later builds download
those exact assets and reject checksum mismatches.

Once credentials and seed assets are present, use **Actions > Build and release
macOS app > Run workflow** on `main`, or push a commit. Inspect the first run's
logs, then install its disk image on another Apple silicon Mac before promoting
a prerelease for general use. A missing-configuration failure on the initial
push can be rerun after setup.

## Updating the selected models

Export and verify new app packages first. Package them into a new directory and
catalog with a new immutable seed tag:

```sh
.venv/bin/python -m scripts.release_models pack \
  --source .local/macos/models \
  --output .local/releases/models-next \
  --catalog .local/releases/models-next.json \
  --tag models-next
```

Use a descriptive version in place of `models-next`. Upload those parts to the
matching seed release, update the notices and model IDs in installation docs,
then replace `release/models.json` with the reviewed catalog and commit it.
The packer rejects existing outputs and checks model packages before and after
archiving. It never trains a model or reads the experiment datasets.

## Local release build

Install both pinned Python environments using [setup.md](setup.md), then set
`GK_SIGNING_IDENTITY`, `GK_TEAM_ID`, and a positive `GK_BUILD_NUMBER` and run
`bash scripts/build_release.sh`. The default output is
`.local/releases/build/assets/GroundKeeper-arm64.dmg`. Use a new
`GK_RELEASE_ROOT` for another build. Local packaging signs the app and disk
image; notarization and stapling are performed by the workflow's next step.
