# Script inventory

Run Python commands from the repository root with `.venv/bin/python -m scripts.NAME`.
Shell scripts are invoked with `bash scripts/NAME.sh`. Inputs, model weights,
and generated outputs stay in ignored `.local/` or `.private/` directories.
Read a command's help and relevant runbook before running it; some commands
download public data, invoke external services, train models, or sign releases.

- **Release**: application packaging, distributed Shortcuts, and maintenance checks.
- **Active experiment**: current diagnostic/evaluation entry points and shared support.
- **Historical**: older preparation, full-run, v2, and Delaware pipelines retained
  for their frozen protocols. This status does not imply an experiment was deployed.

Historical configurations pin paths and code hashes. See
[`experiments/README.md`](../experiments/README.md) before reproducing an old run.
`common_io.py` holds file hashing, JSON output, and JSONL reading without importing
an evaluation runtime. Training generations import it directly.

| Script | Status | Purpose |
| --- | --- | --- |
| [`__init__.py`](__init__.py) | Active experiment | Reproducible local experiment entry points (run with python -m scripts.NAME). |
| [`baselines.py`](baselines.py) | Historical | Lightweight category baseline plus separate public merchant identity benchmark. |
| [`benchmark_apple_shortcuts.py`](benchmark_apple_shortcuts.py) | Active experiment | Resumable serial validation benchmark; final-test partitions are never opened. |
| [`benchmark_merchant_context.py`](benchmark_merchant_context.py) | Active experiment | Compare production baseline/enriched prompts using previously captured evidence. |
| [`benchmark_real_merchant_search.py`](benchmark_real_merchant_search.py) | Active experiment | Frozen real-description DDGS collection and production Qwen comparisons. |
| [`build_receipt_shortcuts.py`](build_receipt_shortcuts.py) | Release | Build reviewed receipt workflows from native Shortcuts action definitions. |
| [`build_release.sh`](build_release.sh) | Release | Build, smoke-test, and package the ad hoc app and installer. |
| [`check_release_background.py`](check_release_background.py) | Release | Exercise SMAppService in a disposable app/container without touching the real agent. |
| [`check_spending_demo.sh`](check_spending_demo.sh) | Release | Verify fictional spending reports against the core. |
| [`check_wallet_priority_shortcuts.py`](check_wallet_priority_shortcuts.py) | Release | Prepare/run a fictional native Shortcuts check without GPS, menus or saves. |
| [`collect_probe_results.py`](collect_probe_results.py) | Historical | Snapshot public experiment evidence; never read private or final-test rows. |
| [`common_io.py`](common_io.py) | Active experiment | Dependency-light file helpers shared by experiment generations. |
| [`database_schema.py`](database_schema.py) | Release | Replay the app's immutable migrations and generate its browsable SQL reference. |
| [`download_model.py`](download_model.py) | Historical | Pinned public model download; no private data leaves this process. |
| [`download_receipt_pilot.py`](download_receipt_pilot.py) | Active experiment | Fetch a reproducible, attributed SROIE image sample without training on it. |
| [`embed_classifier_runtime.py`](embed_classifier_runtime.py) | Release | Embed each service's worker code; the host app owns the shared runtime. |
| [`embed_setup_resources.py`](embed_setup_resources.py) | Release | Bundle the pinned model catalog and available Shortcut installers into the app. |
| [`embed_shared_runtime.py`](embed_shared_runtime.py) | Release | Embed one physical CPython/dependency copy in the host app, shared by both XPCs. |
| [`evaluate_v2_baselines.py`](evaluate_v2_baselines.py) | Historical | Same-set baselines before v2 training. Never access either final test. |
| [`export_classifier_package.py`](export_classifier_package.py) | Release | Export an existing verified experimental model as a data-only app package. |
| [`export_selected_qwen.py`](export_selected_qwen.py) | Release | Package a selected continuation checkpoint against a verified app base package. |
| [`export_text_model.py`](export_text_model.py) | Historical | Drop vision weights using MLX-LM's native sanitizer; preserve 4-bit tensors. |
| [`fetch_sources.py`](fetch_sources.py) | Historical | Download only pinned public source files; respects Hugging Face gating. |
| [`finalize_full_training.py`](finalize_full_training.py) | Historical | Package the frozen validation choice and evaluate the final category test once. |
| [`finalize_v2.py`](finalize_v2.py) | Historical | Package frozen v2 choice, reload copied runtime, then score new test once. |
| [`full_common.py`](full_common.py) | Historical | Evaluation and immutable checkpoint selection for the approved full run. |
| [`full_pipeline.py`](full_pipeline.py) | Historical | Run the approved training and finalization serially under one watchdog. |
| [`full_status.py`](full_status.py) | Historical | Compact, read-only status for the full-run follow-up checks. |
| [`inspect_receipt_layout.swift`](inspect_receipt_layout.swift) | Active experiment | Inspect Vision receipt/document structure for OCR diagnostics. |
| [`laya_experiment.py`](laya_experiment.py) | Historical | Bounded local Laya benchmark/fine-tune; never reads the sealed test. |
| [`laya_pipeline.py`](laya_pipeline.py) | Historical | One finite, detached local training job with automatic packaging/reporting. |
| [`package_probe.py`](package_probe.py) | Historical | Package only the bounded probe; this is NOT an approved production model. |
| [`preflight_v2.py`](preflight_v2.py) | Historical | Freeze a finite v2 configuration after label audit and token/mask checks. |
| [`prepare_canadian_pilot.py`](prepare_canadian_pilot.py) | Historical | Hand-authored synthetic Canadian diagnostic inputs, NEVER real transactions. |
| [`prepare_classifier_runtime.py`](prepare_classifier_runtime.py) | Release | Stage a relocatable, offline CPython/MLX/MPS runtime from pinned local installs. |
| [`prepare_delaware_labels.py`](prepare_delaware_labels.py) | Historical | Prepare and validate an 80-worker public Delaware weak-labeling job. |
| [`prepare_packets.py`](prepare_packets.py) | Historical | Select 50 distinct descriptions per source category, then blind the labelers. |
| [`prepare_training.py`](prepare_training.py) | Historical | Validate immutable annotations, apply adjudications, cap variants, seal splits. |
| [`prepare_v2_audit.py`](prepare_v2_audit.py) | Historical | Select 150 new retained training/validation labels for blind second review. |
| [`prepare_v2_candidates.py`](prepare_v2_candidates.py) | Historical | Pinned public expansion plus explicitly authored US/Canadian coverage seeds. |
| [`prepare_v2_training.py`](prepare_v2_training.py) | Historical | Build coverage-aware v2 partitions without reading the already-used v1 test. |
| [`receipt_case.py`](receipt_case.py) | Active experiment | Run one labeled receipt regression case against actual selected providers. |
| [`receipt_ocr_audit.py`](receipt_ocr_audit.py) | Active experiment | Audit a known receipt against a manually transcribed reference. |
| [`receipt_pilot.py`](receipt_pilot.py) | Active experiment | Evaluate OCR and paired receipt-context predictions on 20 predeclared cases. |
| [`release_models.py`](release_models.py) | Release | Freeze verified local model packages as bounded, checksum-pinned release assets. |
| [`research_merchant_search.py`](research_merchant_search.py) | Active experiment | Bounded, isolated-engine DDGS retrieval diagnostic using public names. |
| [`restore_annotations.py`](restore_annotations.py) | Historical | Restore public ID-based annotations after downloading the pinned source. |
| [`run_bounded.py`](run_bounded.py) | Active experiment | Run one bounded job; record RSS/system headroom without process arguments. |
| [`run_experiment.py`](run_experiment.py) | Historical | Bounded native MLX experiment. Final test labels are never opened here. |
| [`run_full_training.py`](run_full_training.py) | Historical | Approved 632-microbatch run with validation at actual saved checkpoints. |
| [`run_v2_training.py`](run_v2_training.py) | Historical | Train one frozen v2 candidate; serial validation at real saved checkpoints. |
| [`service_modules.py`](service_modules.py) | Release | Explicit shipping and experiment module boundaries for the Python package. |
| [`sign_capture_shortcuts.py`](sign_capture_shortcuts.py) | Release | Sign the reviewed, device-independent capture Shortcut sources for distribution. |
| [`summarize_v2_audit.py`](summarize_v2_audit.py) | Historical | Validate six blind audit returns and expose disagreements for adjudication. |
| [`train_delaware_qwen.py`](train_delaware_qwen.py) | Historical | One bounded, weights-only continuation from Qwen v2 on real weak labels. |
| [`v2_common.py`](v2_common.py) | Historical | Shared v2 evaluation, fixed checkpoint schedule, and integrity gates. |
| [`v2_pipeline.py`](v2_pipeline.py) | Historical | One serial, bounded v2 experiment. Refuse duplicate/restarted pipelines. |
| [`v2_status.py`](v2_status.py) | Historical | Compact read-only preparation/training status; no model or test loading. |

## Retired one-off commands

These six commands have no remaining repository callers. Their results or
completion evidence are retained below. Their source is available in commit
`1fb10d0` using `git show 1fb10d0:scripts/NAME.py`, or from a separate historical
checkout. Existing source/configuration hashes in reports were not rewritten.

| Removed command | Retained evidence |
| --- | --- |
| `audit_packets.py` | [Initial difficult-case audit](../experiments/finetune/AUDIT.md) |
| `evaluate_constrained_v1.py` | [Decoder results](../experiments/finetune/v2/decoder-results) |
| `evaluate_delaware.py` | [100-row diagnostic results](../research/DELAWARE_100_RESULTS_2026-10-17.json) |
| `export_delaware_labels.py` | [Dataset/export audit](../research/DELAWARE_LABELED_DATASET_2026-10-17.md) |
| `rescore_saved_baseline.py` | [Strict baseline](../experiments/finetune/results/baseline_strict_report.json), [rescored baseline](../experiments/finetune/results/baseline_report.json) |
| `verify_delaware_exports.py` | [Qwen/Laya export verification](../research/DELAWARE_LABELED_DATASET_2026-10-17.md#verification) |
