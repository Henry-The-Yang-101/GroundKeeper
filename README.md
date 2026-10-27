# GroundKeeper

https://github.com/user-attachments/assets/1c05f8a8-2805-4429-a71a-42f95de743aa

GroundKeeper is a local-first system designed to automatically help you keep track of personal spending. The GROUND in GroundKeeper means your finances stay grounded on your own devices. The end-to-end system lies strictly within your own personal environment, with no external cloud server ever getting hands on your private transaction data. Your personal iCloud Drive simply delivers capture files from iPhone to Mac, and the files get removed once processed by the Mac, meaning our system will not permanently take up your iCloud storage. YOU are fully in control of your own private data.

## What you can do

- Capture payments on iPhone with Apple Shortcuts, import bank CSVs, or add
  transactions by hand. Accounts support CAD, USD, EUR, and GBP.
- Review CSV imports before saving, resume skipped rows, and combine confirmed
  duplicates while keeping their original records.
- Search, filter, and edit transactions. Review notes, receipts, recorded
  locations, and edit history. Search and filters cover the
  current page of 500 transactions.
- Attach receipts from Photos, Files, or the camera, crop images, and read their
  text locally. You can also capture notes and receipts on iPhone.
- Review category suggestions from Qwen, Laya, Ollama, or Apple Intelligence.
  Model council asks Qwen, Laya, and Apple to vote. Suggestions always need your
  review and cannot overwrite a confirmed correction.
- Explore spending by account, merchant, category, tag, and date. Compare periods,
  see repeat purchases and averages, and group different names for the same merchant.
- See spending changes, trends, and unusually large purchases calculated on your
  Mac. Each finding explains its calculation and links to the transactions behind
  it. You can dismiss findings or snooze them for seven days.
- Protect your database with a passphrase and choose automatic processing while
  the app is open, or use **Import captures** and **Suggest categories** manually.

Reports cover all saved transactions and keep currencies separate. Refunds reduce
spending on their recorded date; transfers and card payments are excluded.
Missing imports and unreviewed categories can limit findings. Budgets,
subscription detection, forecasts, and insight notifications are planned.
See the [spending guide](docs/spending-reports.md) and
[macOS guide](apps/macos/README.md) for details.

## Your data and optional services

Your database stays on your Mac, outside iCloud Drive. After safely saving an
import, GroundKeeper removes its capture file and any retained receipt image
from the iCloud queue. Files that need review stay there until resolved.
Passphrase protection covers the local database, not files waiting in iCloud.
There is no passphrase recovery service.

Spending reports and Qwen, Laya, and Ollama inference run locally. Two optional
features can send information off-device:

- **DuckDuckGo merchant search** sends cleaned merchant names and optional
  city/region details to DuckDuckGo, then shares the results with your chosen
  classifier. It is on by default and can be turned off in Settings.
- **Apple Intelligence** sends transaction details to your selected Shortcut.
  Its **Use Model** action determines whether processing happens on-device or
  in the cloud. Sharing receipt text has a separate setting, on by default.
  Live Apple inference through the sandboxed app remains unverified; see the
  [Apple availability limitation](docs/council.md#apple-availability-limitation).

Receipt images and original captured notes are never sent to classifiers.
Editable transaction notes and receipt text can help with category suggestions.
See [provider setup](docs/setup.md#choose-a-classifier),
[merchant search settings](docs/setup.md#optional-duckduckgo-merchant-context),
and [Council setup](docs/council.md).

Encrypted databases need an interactive unlock and cannot process imports while
the app is closed. Closed-app processing is also disabled in the free release.
Touch ID or Mac-password unlock is available only in provisioned builds; see
[vault protection](docs/onboarding.md#storage-and-unlock).

## Install a release

Follow the [installation guide](docs/install.md) to download the app, complete
macOS's **Open Anyway** step, and set up your phone. The app requires an Apple
silicon Mac and macOS 26.2 or later.

Qwen and Laya models are separate downloads. You can try manual entries, CSV
imports, and spending reports without a model. If you already use Ollama, select
an installed model in Settings; see [Ollama setup](docs/setup.md#ollama).

## Build and try it

You need full Xcode and [uv](https://docs.astral.sh/uv/getting-started/installation/).
The bundled Python version is 3.12.9; Xcode 27.0 is the locally verified toolchain.
With Xcode selected as the developer directory, run:

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

Setup downloads Python and dependencies as needed. All three Python environments
are required to build the current app, even with merchant search disabled.
Model weights are separate. The launcher builds and opens the app; its setup
assistant guides you through database protection, accounts, models, and phone
capture. You can skip models and phone setup.

To try CSV import, add a fictional CAD account and import
[`examples/transactions.csv`](examples/transactions.csv) from Sync. Follow the
[sample walkthrough](examples/README.md). These records go into your normal
local database.

For a separate temporary database with about 600 fictional transactions, run
`./apps/macos/run-demo.sh`. Add `--no-build` to reuse the Debug app. See the
[demo guide](apps/macos/README.md#fictional-spending-demo).

For iPhone capture, follow the [phone setup guide](shortcuts/README.md#iphone-capture-setup).
A Shortcut's success notification means it saved the file; iCloud delivery and
Mac import happen afterward. Real Wallet and CIBC triggers still need device
verification. There is no bank login integration or native iPhone app.

See the [setup guide](docs/setup.md) for signing, models, and troubleshooting.

## Development and tests

Test the Swift core separately from the app:

```sh
swift test --package-path apps/macos/GroundKeeperCore --scratch-path .local/macos/CoreBuild
```

After installing the Python dependencies on Apple silicon:

```sh
.venv/bin/python -m pytest -q -m "not gpu"
```

Python tests are discovered automatically. The default `uv sync` includes the
development group (pytest); `uv sync --no-dev` omits test tools. Run the full
suite without `-m "not gpu"` on a Mac with an available Metal device. Optional
MLX and PyTorch tests skip when their libraries or accelerators are unavailable;
mocked backend and policy tests run on CPU. Check the generated schema reference
with `.venv/bin/python -m scripts.database_schema --check`.

After building Debug, run `./scripts/check_spending_demo.sh` to check the
fictional spending reports in temporary databases. Model inference and signed
app services have separate [smoke checks](apps/macos/README.md#verification).
[CI](.github/workflows/tests.yml) runs core and Python tests without models,
GPU inference, iCloud, or signed app services. Fictional-data checks do not
verify physical-iPhone behavior or accuracy on real spending history.

## Repository guide

| Path | Contents |
| --- | --- |
| [`apps/macos/`](apps/macos/README.md) | Native app, local database, reports, and Swift tests |
| [`groundkeeper/`](groundkeeper/) | Python category models and supporting code |
| [`contracts/`](contracts/) | Shared database, capture, and classifier formats |
| [`docs/`](docs/README.md) | Installation, setup, reports, and other guides |
| [`shortcuts/`](shortcuts/README.md) | iPhone Shortcuts and setup |
| [`examples/`](examples/README.md) | Fictional sample data |
| [`release/`](release/) | Model catalog and release notes |
| [`tests/`](tests/) | Python tests |
| [`scripts/`](scripts/) | Build, release, training, and evaluation tools |
| [`experiments/`](experiments/) | Experiment settings and results |
| [`research/`](research/) | Dataset research and feasibility studies |

Keep generated models and build output in ignored local directories. Private
financial fixtures belong in `.private/` and must stay out of commits.
See the [database implementation](contracts/database/IMPLEMENTATION.md) for
technical details, the [roadmap](docs/roadmap.md) for planned work, and the
[maintainer guide](docs/releases.md) for release publishing.
