# Commit guidance

- Commit semi-frequently, making a commit at each somewhat significant milestone.
- Use the user's configured Git identity as the sole author of commits.
- Do not add co-authors or `Co-authored-by` trailers.

# Project structure

GroundKeeper keeps the native macOS app and Python classifier in one repository.
Paths below are relative to the repository root.

| Path | Purpose |
| --- | --- |
| `apps/macos/` | Native app, Xcode project, signing configuration, launcher, and background-agent definitions. |
| `apps/macos/GroundKeeper/` | SwiftUI application source; see the subfolder guide below. |
| `apps/macos/GroundKeeperCore/` | Standalone Swift package for persistence, imports, reconciliation, classification jobs, receipts/OCR, and model-package validation. Library code and numbered SQL migrations live under `Sources/GroundKeeperCore/`; core tests live under `Tests/GroundKeeperCoreTests/`. `Sources/ReceiptPilot/` contains the receipt pilot executable. |
| `apps/macos/ClassifierService/` | Objective-C XPC host that embeds CPython and runs the classifier outside the UI process. |
| `groundkeeper/` | Python classifier worker, model runtimes, category policies, constrained decoding, merchant utilities, and receipt helpers. |
| `contracts/` | Shared interfaces: database schema/design in `database/`, capture formats in `capture/`, and classifier protocol/runtime pins in `classifier/`. |
| `shortcuts/` | Apple Shortcut exports and setup documentation; editable property-list sources live in `sources/`. |
| `scripts/` | Build/release packaging, runtime preparation, dataset preparation, training, evaluation, and diagnostic commands. |
| `tests/` | Python tests for the worker, contracts, parsing, schema, and experiment utilities. |
| `experiments/` | Experiment configurations, annotations, runbooks, and recorded results, grouped under `finetune/`, `laya/`, `apple-shortcuts/`, and `receipts/`. |
| `research/` | Dataset investigations, feasibility probes, and supporting evidence. |
| `docs/` | Setup, onboarding, installation, release maintenance, category policy, and roadmaps. `history/` preserves earlier scope notes. |
| `examples/` | Fictional sample data and walkthroughs for trying the app. |
| `release/` | Model catalog, model/release notes, and distribution notices/licenses. |
| `.github/workflows/` | CI tests and release automation. |
| `pyproject.toml`, `uv.lock` | Root Python package/dependency configuration and locked dependencies. |

## macOS app source

Within `apps/macos/GroundKeeper/`:

- `App/`: application entry point, root navigation, and sidebar.
- `Features/`: screens grouped by feature, including Home, Transactions, Sync,
  Setup, Settings, and FullInsights. `Features/Shared/` holds shared UI components,
  presentation helpers, and theme code.
- `Models/`: app-facing transaction, navigation, feedback, and preference types.
- `Services/`: workspace coordination, vault access, preferences, classifier/XPC
  client, model installation, background processing, and app smoke checks.
- `Preview/`: fictional fixtures and interface preview support.
- `Resources/`: asset catalogs and bundled fonts/licenses.

## Where new work belongs

- Keep UI in the app, reusable persistence/domain logic in `GroundKeeperCore`,
  and Python inference code in `groundkeeper/`. Swift owns the live database;
  the classifier receives requests through the shared contract.
- Put operational commands in `scripts/` and experiment-specific configuration
  and reports in `experiments/`. Keep research findings separate from implemented
  behavior; a roadmap or experiment result does not establish a shipped feature.
- Add database changes as new numbered migrations under
  `apps/macos/GroundKeeperCore/Sources/GroundKeeperCore/Resources/`; do not edit
  an applied migration. Keep relevant contract documentation current.
- Preserve existing root Python paths: scripts and saved reports use
  repository-relative paths. Update callers together if a move is necessary.
- Generated runtimes, models, checkpoints, caches, and build output belong in
  ignored local directories such as `.local/`; `.venv/` holds the root Python
  environment. Private financial fixtures belong in ignored `.private/`.
  Keep live databases, iCloud capture files, credentials, and signing keys out of
  Git. The live vault stays outside iCloud and outside the source tree.
- Use `README.md` and the relevant directory README for commands and setup;
  use `contracts/database/IMPLEMENTATION.md` for current database behavior and
  `docs/roadmap.md` for planned work.
