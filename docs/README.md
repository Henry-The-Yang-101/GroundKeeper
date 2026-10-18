# Documentation

Start with [setup](setup.md) to build the app and try it with fictional data.
The [macOS guide](../apps/macos/README.md) covers queue processing, development
signing, and app smoke checks.

## Product and architecture

- [Roadmap](roadmap.md): product requirements, remaining work, and proposed designs.
- [Transaction categories](transaction-categories.md): category definitions,
  transaction types, and review semantics.
- [Analytics roadmap](analytics-roadmap.md): planned reports, budgets, goals,
  and their data requirements.
- [Database implementation](../contracts/database/IMPLEMENTATION.md): current
  SQLite behavior, ingestion, reconciliation, and durable jobs.
- [Database schema](../contracts/database/SCHEMA.md): relational design and
  invariants, including tables reserved for future features.
- [Classifier bridge](../contracts/classifier/README.md): XPC protocol, model
  manifests, runtime pins, cancellation, and isolation.

## Experiments

Experiment reports record the data, model, and limitations for each run. Local
paths under `.local/` identify generated artifacts that are not included in Git.
Reproducing a training run requires the inputs listed in its runbook.

- [Laya](../experiments/laya/README.md): typed decisions and supervised fine-tuning.
- [Qwen](../experiments/finetune/README.md): JSON classification experiments.
- [Qwen v2](../experiments/finetune/v2/RUNBOOK.md): merchant-group splits,
  labeling audits, checkpoint selection, and evaluation procedure.
- [Delaware continuation](../experiments/finetune/delaware-v1/RUNBOOK.md):
  training with public merchant descriptions and AI weak labels.
- [Apple Shortcuts](../experiments/apple-shortcuts/README.md): provider
  benchmarks, saved responses, and quota limits.

AI label agreement and synthetic test scores do not establish accuracy on a
user's bank transactions. The app requires review for every model suggestion.

## Historical notes

[Initial scope and feasibility probes](history/m0-scope.md) preserve the early
capture, model, and Secure Enclave investigations. They describe earlier
assumptions and do not replace the current setup or implementation guides.
Additional dataset investigations are under [`research/`](../research/).
