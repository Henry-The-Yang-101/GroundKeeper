# Setup

For a compiled app, follow the [release installation guide](install.md).
For a source build, run commands from the repository root. The first build needs
internet access to install dependencies. The packaged local classifiers can run
offline once a model package is available.

## Requirements

- Apple silicon and macOS 26.2 or later for the full app and bundled MLX runtime.
- Full Xcode with its command-line tools selected. Xcode 27.0 is the locally
  verified version. Open Xcode once to finish its installation and license setup.
- [uv](https://docs.astral.sh/uv/getting-started/installation/) to install the
  pinned Python environments.
- No Apple account is required for ad hoc builds. An Apple Development signing
  identity is optional for local development.

Check which Xcode the terminal will use:

```sh
xcode-select -p
xcodebuild -version
```

If `xcode-select` points to Command Line Tools instead of your full Xcode
installation, select Xcode in **Xcode > Settings > Locations > Command Line
Tools**. The standalone Swift core targets macOS 14 or later, but that does not
lower the full app's macOS requirement. Building the core requires Xcode 26 or
later for the receipt OCR APIs in the macOS 26 SDK; runtime availability checks
select the older OCR API on earlier macOS versions. The core CI job selects
Xcode 26.2 explicitly because the macOS 15 runner defaults to Xcode 16.4.

## Install dependencies and build

```sh
git clone https://github.com/Henry-The-Yang-101/GroundKeeper.git
cd GroundKeeper

uv sync --locked --python 3.12.9
uv venv --python .venv/bin/python .local/laya/.venv
uv pip install --python .local/laya/.venv/bin/python -r experiments/laya/requirements.lock
uv venv --python .venv/bin/python .local/merchant-search-ddgs/venv
uv pip install --python .local/merchant-search-ddgs/venv/bin/python -r experiments/merchant-search/requirements.txt

./apps/macos/run.sh
```

For an existing checkout, skip cloning and reuse its environments. Do not
recreate an environment while a training or inference process is using it.

`uv.lock` fixes the project dependencies. Laya and PyTorch use a separate
environment pinned by `experiments/laya/requirements.lock`. The runtime preparer
selects packages from those environments and the separately pinned DDGS build
environment (`experiments/merchant-search/requirements.txt`), checking the dependency
closure against `contracts/classifier/runtime-lock.json`, including the exact
Python patch version. A mismatch stops the build.

The launcher stages CPython and native libraries under
`.local/macos/classifier-runtime`, then builds and opens:

```text
.local/macos/DerivedData/Build/Products/Debug/GroundKeeper.app
```

The built app contains its Python runtime. It does not launch your development
virtual environment. Weights are loaded from a separately selected model
package; the build does not download or train a model.

## Optional DuckDuckGo merchant context

In **Settings > Categorization**, **Use DuckDuckGo merchant search** is on by
default and applies to pending/future classifications for Qwen,
Laya, and the selected Apple Intelligence Shortcut. Confirmed assignments are
preserved. Optionally enter a city/region and click **Save search locality**.

**Include receipt text with Apple Intelligence** is also on by default. Both
settings preserve saved choices, including an explicit off setting, and can be
turned off independently in Settings.

The Mac sends only a cleaned merchant name (or cleaned transaction description)
and optional locality to DuckDuckGo's HTML search endpoint through DDGS 9.16.0.
It sends no amount, account/card identifier, receipt, precise coordinate or full
transaction object. Unsafe queries are skipped. Searches require internet
access; "run from this Mac" does not mean offline search. There is no hosted
GroundKeeper search backend, API key, or other-engine fallback.

Uncached queries are serialized with a 10.5-second pause after the preceding
search finishes, producing roughly 11-second search-start spacing in the
experiment. Inference adds processing time. This is experimental pacing, not
a guaranteed DuckDuckGo limit. CAPTCHA/403/429 pauses new searches for at least
15 minutes; other failures back off for one minute. Classification continues
without web evidence. Cancellations preserve a conservative reservation.

Matched snippets cache for 30 days; no-match results cache for one day. The vault
retains at most 1,000 entries. **Clear search cache** removes reusable entries;
immutable run evidence remains for audit. Turning the toggle off prevents new
searches and subsequent use of cached search evidence. Local models remain
local; Apple Intelligence receives the context too and may process it in the
cloud according to the Shortcut's Use Model action.

Reimport the updated **GK Categorize Cloud** or **GK Categorize On-Device**
installer when using that provider. Keep the action's built-in web search off.
Every result still requires review; improved classification accuracy has not
been established. See [architecture and evaluation](../contracts/classifier/README.md#merchant-search-evidence).

## First run

1. Complete the first-launch assistant: choose vault protection, optional models,
   an iCloud capture folder, phone setup, and an account. You can skip model
   downloads and phone setup. Return through **Settings > Review setup assistant**.
2. Leave queue processing at **Only while GroundKeeper is open**, or select
   **Manually** for manual control.
3. Add a transaction with Command-N, or import a CSV from Sync. The
   [fictional CSV walkthrough](../examples/README.md) works without a classifier.
4. Select a classifier when you are ready to try category suggestions.

The app starts with an empty database. Manual entries, CSV imports, and sample
records you add all persist in the same local database:

```text
~/Library/Containers/com.groundkeeper.macos/Data/Library/Application Support/GroundKeeper/vault.sqlite
```

Choose unencrypted SQLite or SQLCipher with a passphrase. Provisioned builds
also offer Touch ID / Mac password convenience unlock. Keep the live database
outside iCloud Drive. Backup and recovery tooling is still planned; keep your
passphrase safe. See [vault protection and setup](onboarding.md).

## Choose a classifier

### Local Qwen or Laya

In setup or **Settings > Install models or choose a provider**, install Qwen,
Laya, or both. Downloads use the bundled release catalog and verify every part
before extraction. To use an existing package, click **Choose local model package** and
select a directory containing `classifier.json` and its model files. The worker
checks the file set, sizes, hashes, policy, and package format before loading.
Qwen runs on MLX; Laya runs on PyTorch MPS. Each package is limited to 3 GB.

The release workflow attaches the pinned Qwen and Laya packages as separate
[release downloads](install.md#install-the-local-models). They are not stored in
Git. A fresh clone can run the ledger and CSV workflow without them. A raw
Hugging Face download is not yet an app package.

If you already have a verified experimental package, the
[classifier package guide](../contracts/classifier/README.md#model-packages)
describes how to export it. The macOS guide also records the
[selected Qwen continuation export](../apps/macos/README.md#classifier-providers).
Those commands require existing checkpoint and manifest files under `.local/`.
The [experiment index](README.md#experiments) links to training procedures and
their dataset requirements.

### Ollama

You can use an existing local Ollama model instead of downloading GroundKeeper's
Qwen or Laya packages:

1. Install [Ollama for macOS](https://ollama.com/download/mac) if needed, open it,
   and install a chat or instruction model through Ollama.
2. In Setup's **Intelligence** step or **Settings > Install models or choose a
   provider**, find **Ollama** and click **Refresh Ollama models**.
3. Select an installed model and click **Use Ollama model**. This saves the choice
   for future launches and queue processing. In manual processing mode, click
   **Suggest categories** to request suggestions.

GroundKeeper connects to `127.0.0.1:11434`; custom ports and remote servers are
not supported. It does not download models, start Ollama, change its settings,
or fall back to another provider. Ollama must be running whenever classification
is needed. Cloud tags and aliases reporting a remote model/host are excluded;
embedding-only models cannot be used. General models vary in quality and speed
and have not been evaluated against GroundKeeper's fine-tuned models.

Inputs use the existing description/direction/currency contract, with available
editable transaction notes, receipt evidence, Wallet hints, and separately
enabled merchant search context.
Raw amounts, images, capture notes and the vault database are not sent. Output
uses the same category policy and always requires review. Invalid output leaves
the existing categorization intact and records a failed attempt. Temporary
connection/deadline errors use the queue's existing bounded retries; **Retry
failed** explicitly retries failed work. When a model is removed or its digest
changes, refresh and select it again. Its new identity gets separate audit/jobs.

Ollama runs as a separate user-managed process. GroundKeeper checks its model
metadata before sending evidence and rejects HTTP redirects and proxies. For
Ollama's own local-only configuration, see its
[cloud settings](https://docs.ollama.com/faq#how-do-i-disable-ollamas-cloud-features).

### Model council

Open **Settings > Install models or choose a provider** and find **Model council**.
Install both local models if needed, then select the Qwen and Laya packages for
Council. Installed packages have a **Use installed Qwen/Laya** shortcut; existing
packages can be selected with the individual directory pickers. Enter the
installed Apple Intelligence Shortcut name and inspect its Use Model action.

Click **Enable Council with Apple Intelligence** to verify the packages and
select Council. Each provider gets one vote. Two matching type/category decisions
produce a suggestion, and every result needs review. If one provider is unavailable,
the other two can produce a visibly partial result when they agree. Otherwise,
Council keeps the current categorization and records no consensus.

DuckDuckGo search and sharing receipt text with Apple remain separate settings.
Search is optional; one saved evidence snapshot is reused across members and
retries. Receipt text stays local unless the Apple receipt-sharing option is on.

Open a transaction with **Edit** and expand **Member decisions and sources** to
inspect the saved votes and failures. **Retry failed** in Sync requeues failed
attempts; in manual mode, click **Suggest categories** to run them. Package and Shortcut
edits in Council setup are drafts until **Apply council setup** is clicked.

### Apple Intelligence through Shortcuts

1. Import [`GK Categorize Cloud.shortcut`](../shortcuts/GK%20Categorize%20Cloud.shortcut)
   into the macOS Shortcuts app.
2. Inspect its **Use Model** action. The export was configured for Cloud with
   Broad World Knowledge enabled, Text output, and Follow Up disabled. Your Mac
   must support the selected Apple Intelligence action and have it enabled.
3. In **Settings > Categorization**, enter the installed Shortcut's exact name
   and click **Use Apple Intelligence Shortcut**.
4. Process a fictional transaction first and review the result or reported error.

Only description, direction, and currency are sent to the Shortcut. Its contents
determine which service receives them. GroundKeeper records this provider as
cloud-capable and never silently falls back to it from a local model.

The direct CLI benchmark produced predictions, but the latest signed app
integration check reached Apple's usage limit. A successful prediction through
the app still needs verification after that limit resets. Quota or configuration
errors require **Retry failed work**; the app does not invent a category when a
provider fails. See the [benchmark notes](../experiments/apple-shortcuts/README.md).

## iPhone capture and iCloud

The Mac importer reads versioned JSON events from a GroundKeeper iCloud Drive
folder or its `inbox` subfolder. Use **Sync > Connect folder** to grant access,
then confirm captured card labels against your accounts in the review list.
Source files remain in iCloud after import. Persisted delivery identities prevent
re-importing unchanged files.

The app bundles signed capture and classifier Shortcuts, with install/share
buttons and a phone setup guide. You must create personal automations and select
cards/folder permissions on the receiving iPhone. See the
[Shortcuts guide](../shortcuts/README.md) and the
[accepted envelope types](../apps/macos/GroundKeeperCore/Sources/GroundKeeperCore/Models.swift)
and [ingestion behavior](../contracts/database/IMPLEMENTATION.md).

Real Wallet taps, locked-phone capture, and broader notification formats still
need device testing. Unknown formats appear for review with their original
evidence preserved.

## Background processing and signing

Source builds expose background mode through an `SMAppService` launch agent.
The free ad hoc release disables it after a replacement-build launch failure. Enable **Automatically in
the background** in Settings. Apple development signing is optional; the
[signing steps](../apps/macos/README.md#configure-apple-development-signing)
cover that configuration. macOS may ask you
to allow GroundKeeper in Login Items & Extensions.

The helper runs while the Mac is awake and hands database ownership back to the
foreground app when it opens. Local development checks covered quitting and
reopening the app; login and reboot behavior still need a full device check.
The free release uses ad hoc signatures and is not notarized. After an update,
re-enable the service or reconnect folders if saved permissions stop working.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Missing `.venv/bin/python` or Laya interpreter | Complete both environment setup steps before running the launcher. |
| Installed runtime differs from the lock | Check Python 3.12.9 and both pinned dependency files. Avoid upgrading packages independently. `--rebuild` does not bypass a version mismatch. |
| Xcode cannot find the macOS SDK | Select the full Xcode installation and complete its first launch. |
| Model package rejected | Select the exported directory with `classifier.json`. A raw model folder or modified file set will fail verification. |
| Transactions have no category | Choose a valid provider and check queue mode, pending work, and failures. Every successful suggestion still requires review. |
| Background service is registered but idle | Check Login Items approval, re-enable the service after updates, and check the helper status shown in Settings. Registration alone does not establish that it is running. |

For changes to the core or worker, run the tests in the
[root README](../README.md#development-and-tests). GPU, XPC, and background
behavior have additional [smoke checks](../apps/macos/README.md#verification).
