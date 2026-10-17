# GroundKeeper

GroundKeeper is scoped to a **macOS app**, **Apple Shortcuts on iPhone**, and
**iCloud Drive** for exchanging files. There is no planned native iPhone app.

The repository contains a native SwiftUI macOS app, Python classification code,
model-training experiments, and research. The app provides a native sidebar,
spending-chart previews, searchable and editable sample transactions, a CSV
walkthrough, and appearance settings. Sample edits stay in memory; charts use
fixed examples. Capture, storage, classification, and financial analysis are
not connected yet.

Settings also provides local classifier diagnostics through a bundled XPC
service with isolated Python, MLX Metal and PyTorch MPS. It can load a verified
model package and classify explicitly entered sample text; it does not yet
categorize or persist the transaction workspace. See the
[classifier bridge guide](contracts/classifier/README.md). The bundled build
currently requires Apple silicon and macOS 26.2+.

From the repository root, build and launch the app with:

```sh
./apps/macos/run.sh
```

See the [macOS app guide](apps/macos/README.md) for Xcode setup.

## Current repository map

| Path | Purpose |
| --- | --- |
| [`apps/macos/`](apps/macos/README.md) | Native SwiftUI macOS app and Xcode project |
| `groundkeeper/` | Existing Python classification, merchant, policy, and runtime code |
| `scripts/` | Dataset preparation, training, evaluation, packaging, and status commands |
| `tests/` | Existing Python tests |
| `experiments/` | Versioned experiment configurations, annotations, reports, and results |
| `research/` | Earlier research and feasibility probes |
| `.local/` | Ignored model downloads, checkpoints, generated datasets, and run state |
| `.private/` | Ignored location reserved for private development fixtures |
| [`TRANSACTION_CATEGORIES.md`](TRANSACTION_CATEGORIES.md) | Spending categories, transaction types, and review semantics |
| [`M0_SCOPE.md`](M0_SCOPE.md) | Capture assumptions, measured feasibility, and remaining checks |
| [`PLAN.md`](PLAN.md) | Current product plan, classifier choices, architecture proposals, and delivery gates |
| [`ANALYSIS_FEATURES.md`](ANALYSIS_FEATURES.md) | Graphs, budgets, goals, cash flow, and net-worth roadmap with data requirements |
| [`contracts/database/SCHEMA.md`](contracts/database/SCHEMA.md) | Proposed SQLite/SQLCipher schema, source reconciliation, optional geotags, category/model provenance, and service invariants |
| [`contracts/classifier/README.md`](contracts/classifier/README.md) | Bundled XPC/Python classifier, runtime pins, model packages, GPU execution and verification |

`PLAN.md` reflects the current native macOS direction, with local Laya/Qwen,
optional Apple Intelligence cloud via Shortcuts, and a weighted Council mode.
It distinguishes product requirements from architecture proposals and open
decisions.

## Suggested organization

Keep the Python package and its project configuration at the root for now.
Organize new product work around these boundaries:

```text
GroudKeeper/
  README.md
  AGENTS.md
  apps/
    macos/                      # native app, Xcode project, reserved test folder
  shortcuts/                    # proposed: iPhone capture exports and setup guide
  contracts/                    # database design; iCloud event schema still planned
  docs/                         # proposed: current architecture, setup, decisions
  groundkeeper/                 # existing Python code
  scripts/                      # existing command-line entry points
  tests/                        # existing Python tests
  experiments/                  # existing reproducible experimental evidence
  research/                     # existing exploratory work
  pyproject.toml
  uv.lock
  .local/                       # ignored generated artifacts
  .private/                     # ignored private development data
```

Recommended next steps, without moving existing files in this initialization:

1. Put production iPhone capture `.shortcut` exports and their installation guide
   in `shortcuts/`. Keep `experiments/apple-shortcuts/` as benchmark evidence:
   its existing Shortcut performs cloud categorization, not iPhone capture.
2. Define the iCloud Drive file contract in `contracts/` before connecting the
   app and Shortcut. Include a schema version, stable event ID, timestamp,
   source fields, and redacted examples. Treat the synced folder as a handoff;
   keep the Mac's live database and model files outside it. Use the existing
   queue/staging proposal as input, with delivery, retries, and deduplication
   still to be specified and verified.
3. Move current product documentation into `docs/` together with updates to
   links and command references. Keep historical findings with their experiment.
4. As scripts grow, group them by function (`data`, `training`, `evaluation`,
   `packaging`). Migrate imports, command examples, tests, and automation paths
   together; several current commands depend on repository-relative paths.
5. Revisit a separate Python worker folder when the app-to-classifier interface
   is implemented. For now, keeping `groundkeeper/`, `scripts/`, and the uv files
   in place avoids a disruptive move during ongoing experiments.

iCloud runtime files belong in the user's configured iCloud Drive location,
outside this Git repository. Version safe fixtures and aggregate results;
keep real financial input and model artifacts out of Git.
