# Release maintenance

Every push to `main` starts [release.yml](../.github/workflows/release.yml).
It tests the Python and Swift code and builds an arm64 Release app with the
pinned Python runtime. The app and its disk image use ad hoc signatures.
No Apple account, signing certificate, paid membership, or Apple secrets are
needed. The app is not notarized.

The build checks signatures, opens a temporary ledger, and tests the actual
XPC connection and Python worker without requiring a GPU. A second job verifies
the pinned model archives and publishes the app, models, Shortcuts, installation
instructions, and checksums together as a GitHub prerelease.

Tags use `build-<run number>-<commit>-<attempt>`. Failed tests, missing model
assets, or invalid signatures stop publication. The app build itself does not
need the seed assets: its disk image is also saved as the `adhoc-installer`
Actions artifact, even if the publish job cannot find the models. Uploads first go to a draft
release, so an interrupted upload is not presented as a complete download.
A failed publish job may leave a draft to remove or inspect.

## Repository setup

Enable GitHub Actions for the repository. The publish job uses GitHub's
automatic token with `contents: write`; no personal GitHub token is required.
Any Apple signing secrets from an earlier configuration are unused and can be
removed from the repository settings.

The workflow uses GitHub's [`xcode-27` arm64 image](https://github.com/actions/runner-images).
Confirm that this runner is available for the repository. The release job
excludes the single MLX logits test that needs Metal; run the full Python suite
locally on Apple silicon. Hosted CI does not validate GPU inference, real iPhone
capture, or login/reboot behavior.

Ad hoc signatures provide local code integrity but no verified developer
identity. Downloaded apps may be blocked on first launch. The
[installation guide](install.md) explains Apple's per-app **Open Anyway** flow.
Do not tell users to disable Gatekeeper globally.

The worker accepts an ad hoc peer only if its code hash matches the enclosing
app. A transient bookmark grants read access to that app bundle for the identity
check; a fresh connection token blocks requests queued before authentication.
Its bundled Python and ML libraries need a library-validation exception in the
sandboxed worker because ad hoc signatures have no Team ID. The ad hoc main app
also needs this exception for its bundled SQLCipher framework. Provisioned main
app builds retain library validation and re-sign SQLCipher with the app identity.
Model packages still reject executable code and verify their data files before loading.

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

Once the seed assets are present, use **Actions > Build and release
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

Install both pinned Python environments using [setup.md](setup.md), then run:

```sh
GK_BUILD_NUMBER=1 bash scripts/build_release.sh
```

The output is `.local/releases/build/assets/GroundKeeper-arm64.dmg`. Use a new
`GK_RELEASE_ROOT` for another build. The script explicitly clears the signing
team and uses ad hoc signing even if your private Xcode configuration selects
an Apple Development identity. It performs no notarization or network signing.

For local GPU checks, run the built app with `--classifier-smoke`. For background
launch diagnostics, the following command deliberately bypasses the product's
background-mode gate in an isolated copy:

```sh
.venv/bin/python -m scripts.check_release_background \
  .local/releases/build/DerivedData/Build/Products/Release/GroundKeeper.app
```

That diagnostic uses a disposable copy with a separate bundle ID, container,
and launchd label. It unregisters the diagnostic service afterward. It may fail
because of platform policy; it is not a hosted CI gate.

## Local verification and background limits

On 2026-10-18, the ad hoc Release app passed the XPC/Python handshake, protocol
errors, cancellation, GPU probes, and three fictional classifications with each
pinned model. Qwen used MLX GPU and Laya used MPS. These are integration checks,
not accuracy measurements. Native signature tests reject a different executable
with the same bundle ID, modified hosts, and unsigned code. XPC smoke tests
reject pre-authorization guesses and a nonce replayed on another connection.

One isolated background launch processed the 205-file fictional queue. Repeating
that check with a replacement build failed with `CODESIGNING: Launch Constraint
Violation`, despite successful registration. The free release therefore sets
`GKDistributionChannel=adhoc`, hides closed-app background mode, and rejects
attempts to enable it. Previously saved background mode becomes while-open mode.
The headless production agent exits without processing in this distribution.
Source builds retain background support; an enable failure restores the prior
processing mode rather than leaving the app in a nonworking background state.

Automatic while-open and manual processing pass the Release queue smoke test.
Login, reboot, and installation on a clean second Mac remain unverified.
