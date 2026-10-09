# GroundKeeper

GroundKeeper is scoped to a **macOS app**, **Apple Shortcuts on iPhone**, and
**iCloud Drive** for exchanging files. There is no planned native iPhone app.

The repository currently contains Python classification code, model-training
experiments, and research. The macOS app folder is initialized, but does not yet
contain an Xcode project or a runnable app.

## Current repository map

| Path | Purpose |
| --- | --- |
| [`apps/macos/`](apps/macos/README.md) | Native macOS app scaffold; recommended implementation: SwiftUI |
| `groundkeeper/` | Existing Python classification, merchant, policy, and runtime code |
| `scripts/` | Dataset preparation, training, evaluation, packaging, and status commands |
| `tests/` | Existing Python tests |
| `experiments/` | Versioned experiment configurations, annotations, reports, and results |
| `research/` | Earlier research and feasibility probes |
| `.local/` | Ignored model downloads, checkpoints, generated datasets, and run state |
| `.private/` | Ignored location reserved for private development fixtures |
| [`TRANSACTION_CATEGORIES.md`](TRANSACTION_CATEGORIES.md) | Spending categories, transaction types, and review semantics |
| [`M0_SCOPE.md`](M0_SCOPE.md) | Capture assumptions, measured feasibility, and remaining checks |
| [`PLAN.md`](PLAN.md) | Earlier architecture proposal; includes a localhost dashboard and older model assumptions |

The platform scope above is the current direction. `PLAN.md` needs reconciliation
before implementation; its earlier dashboard and model choices are not decisions
for the new macOS app.

## Suggested organization

Keep the Python package and its project configuration at the root for now.
Organize new product work around these boundaries:

```text
GroudKeeper/
  README.md
  AGENTS.md
  apps/
    macos/                      # initialized: native app sources and tests
  shortcuts/                    # proposed: iPhone capture exports and setup guide
  contracts/                    # proposed: iCloud file schemas and safe examples
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
