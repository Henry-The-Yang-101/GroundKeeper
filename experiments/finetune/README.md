# GroundKeeper local fine-tuning experiment

This is a reproducible public/synthetic-data experiment, not a deployed personal
finance classifier. Read LABELING_POLICY.md, AUDIT.md, dataset_report.json and the
measured RESULTS.md before approving a full run. All private transactions remain
outside Git and outside cloud subagent prompts. No private transaction was used.

The model output remains a JSON object, as reaffirmed by the user:

```json
{"type":"expense","category":"dining","review":false}
```

All three fields are training targets. There is no numeric confidence field;
`review` expresses the labeling policy's need for review, not a calibrated
probability. The application can require review even if the model returns false.
Invalid model answers become unknown/uncategorized with review=true. JSON key
order is immaterial; category-only text is not accepted or trained as the target.

## Reproduce preparation

Run from the repository root on Apple Silicon. `uv.lock` pins Python dependencies;
`uv sync --python 3.12` installs them into the ignored `.venv`. Public source/model
revision hashes are pinned in the scripts. Downloads are an explicit setup step;
model inference/training runs with Hugging Face offline mode.

```sh
uv sync --python 3.12
.venv/bin/python scripts/run_bounded.py --seconds 600 --label source-download -- .venv/bin/python scripts/fetch_sources.py
.venv/bin/python scripts/prepare_packets.py
.venv/bin/python scripts/prepare_canadian_pilot.py
.venv/bin/python -m scripts.restore_annotations
.venv/bin/python -m scripts.prepare_training
.venv/bin/python -m pytest -q
.venv/bin/python scripts/run_bounded.py --seconds 900 --label model-download -- .venv/bin/python scripts/download_model.py
.venv/bin/python scripts/run_bounded.py --seconds 300 --label text-export -- .venv/bin/python scripts/export_text_model.py
.venv/bin/python scripts/run_bounded.py --seconds 180 --label compatibility-check -- .venv/bin/python -m scripts.run_experiment check
```

Existing text exports and adapters are protected against accidental overwrite.
For a new experiment, use a distinct run directory rather than replacing frozen
artifacts. The watchdog persists a four-hour session deadline in
`.local/finetune/runs/overall_deadline.json`. It rejects jobs after that deadline;
start a deliberate new session before future work (archive the completed runs
folder, then create a fresh runs folder). Do not reset a deadline while a job runs.
It records process names/PIDs/RSS, elapsed time and system headroom, stops child
process groups at per-run limits, and aborts on low memory. It never logs process
command lines from unrelated applications.

`fetch_sources.py` skips the gated Mitul dataset by default. `--include-gated` is
only for an account with accepted access. The ungated alternatives assessed in
AUDIT.md were not silently substituted or used as mirrors of gated data.

## Labeling and leakage controls

- Initial audit: 60 difficult US synthetic cases, three Luna 6 agents, 20 each;
  parent reviewed every decision before bulk labeling.
- Bulk: 38 packets of 25, totaling 850 DoDataThings rows (50 per original category)
  and 100 authored Canadian-style diagnostic rows. Each assignment capped at 25.
  Initial packet effort inherited the available default; packets 009–037 used
  explicitly requested `gpt-6-luna` with `xhigh`. These are AI-reviewed, not human
  labels. The US and Canadian sources are both included.
- Second pass: 75 blind relabelings, oversampling difficult training/validation
  cases, by three fresh Luna 6 xhigh agents. Agreement was 69/75 before parent
  adjudication. This is not accuracy against independent human truth.
- Annotator IDs, evidence, disposition, model and effort are versioned in
  public_annotations.jsonl. The original labels are immutable; adjudications.json
  and annotation_adjustments.jsonl preserve corrections. Private data must never
  be placed in these public annotation files.
- Canonical chain/parent aliases and exact-description unions keep merchant
  variants together across both sources. At most six examples per group survive.
  Split hashing has one fixed seed/salt and is not retried for favorable scores.
  Grouping is manually reviewed and conservative, not a guarantee against every
  possible unrecognized corporate relationship.
- No augmentation is performed. Split manifests contain public IDs, merchant
  groups and input hashes, not private descriptions. The final test records live
  separately under `.local/finetune/sealed_test_records.jsonl`; experiment code
  opens only train and validation. Do not score the final test while choosing
  settings. A chronological known-merchant real test is unavailable.

## Baselines, training and packaging

```sh
.venv/bin/python scripts/run_bounded.py --seconds 180 --label classifier-baseline -- .venv/bin/python -m scripts.baselines category
.venv/bin/python -m scripts.baselines merchants
.venv/bin/python scripts/run_bounded.py --seconds 900 --label prompted-baseline -- .venv/bin/python -m scripts.run_experiment baseline
.venv/bin/python scripts/run_bounded.py --seconds 1800 --label qlora-probe -- .venv/bin/python -m scripts.run_experiment probe
.venv/bin/python scripts/run_bounded.py --seconds 900 --label probe-validation -- .venv/bin/python -m scripts.run_experiment probe-eval
.venv/bin/python scripts/run_bounded.py --seconds 180 --label probe-package -- .venv/bin/python -m scripts.package_probe
.venv/bin/python scripts/collect_probe_results.py
```

The probe is 128 microbatches and 16 optimizer updates, not 128 optimizer updates.
It starts from the untouched quantized base, uses rank 8 on the last four hybrid
layers, microbatch 1, accumulation 8, Adam at 5e-5, maximum length 512, gradient
checkpointing, and prompt masking. Architecture-specific targets are in
probe_config.json. Compatibility checking verifies trainable layer indices and
exact training/inference token prefixes; it fails rather than truncate.

The source VLM's MLX sanitizer drops vision weights. Export preserves the 4-bit
text tensors and makes disabled thinking the tokenizer-template default, so the
native trainer and inference agree. No remote code is trusted. Production and
evaluation share the same compact policy, prompt builder and schema validator.
The parser accepts plain JSON or a single whole Markdown JSON fence, then checks
exact fields/enums/invariants; prose and unsupported fields are rejected. The
first strict baseline and its rescoring evidence are retained separately.

Checkpoints are diagnostic. The proposed full run must begin from the original
base, not continue the probe, and requires the user's explicit approval after
measured memory/runtime are available. Final test scoring is still deferred.
The user approved `proposed_full_config.json` on 2026-10-09. The separate full
runner uses that exact configuration, explicitly seeds NumPy and MLX, scores
each actual checkpoint during training, freezes selection, and then evaluates
the final category test once through the packaged runtime. The original probe
entry point continues to support probe work only.

That full run is now complete. Checkpoint 512 was selected before final testing;
the complete run took 35.95 minutes and its package is 2,389,468,280 bytes. See
[full-results/RESULTS.md](full-results/RESULTS.md) for the final comparison,
one-time synthetic test, exact runtime checks and limitations. Do not rerun the
completed pipeline or use its final test for further model selection.
The package includes one base, one adapter, tokenizer, configs, template and
manifest, with an exact decimal-byte total. The probe package is clearly marked
experimental. The original base remains available for rollback.

## Merchant memory and review

`groundkeeper.merchant.MerchantMemory` takes an already unlocked caller-owned
connection (in-memory SQLite in tests; the eventual application's SQLCipher
connection in production). It never opens a plaintext private database or obtains
keys. The locked job passes None and cannot inspect personal memory.

Purchase corrections default to transaction scope. Merchant-wide rules require
an explicit flag. Lookups exclude confirmations later than their as-of time.
Public reference pairs are stored separately and never become confirmed aliases.
Fuzzy lookup checks score and runner-up margin, including distinct purposes at
the same chain. Thresholds remain uncalibrated, so fuzzy matches require review.
The separate Crossing Minds benchmark evaluates only public merchant identity,
not category correctness or private confirmation. No threshold met its held-out
criterion; no fuzzy acceptance threshold is deployed.

`groundkeeper.runtime.LocalCategorizer.suggest` requires local paths and always
returns review=true until representative real held-out calibration is available.
Metrics separately report semantic suggestions, invalid outputs and automatic
coverage. Zero acceptance has an undefined error rate, not a perfect one.

Known limitations: AI labels; synthetic regional formatting; sparse gifts/taxes/
Other/principal/refund coverage; no real corpus, calibrated acceptance threshold,
future-known-merchant test, or production SQLCipher/dashboard integration. This
experiment does not complete M0–M6 of the original application architecture.

## Approved full run

The full pipeline refuses to overwrite adapters or an existing package. Do not
restart it while it is active. Run the read-only status command first.

```sh
.venv/bin/python -m scripts.full_status
.venv/bin/python scripts/run_bounded.py --seconds 180 --label full-preflight -- .venv/bin/python -m scripts.run_full_training --check-only
.venv/bin/python scripts/run_bounded.py --runs-dir .local/finetune/full-v1/runs --overall-seconds 3600 --seconds 3600 --label full-training -- /usr/bin/caffeinate -i .venv/bin/python -m scripts.full_pipeline
```

The full job has its own 60-minute deadline, a 50-minute training/evaluation
phase bound and a 10-minute finalization bound. Existing probe deadlines and
artifacts are preserved. `caffeinate -i` prevents idle sleep while the job runs.
The existing process RSS and available-memory safeguards remain active.

Checkpoint evaluation pauses training and uses the same model instance, avoiding
a second GPU model. It saves the adapter before evaluation and preserves NumPy
shuffle state. JSON reports are written atomically for progress monitoring.
Checkpoint selection requires all five reports and uses macro-F1, then exact
three-field accuracy, fewer invalid outputs, and earlier step. The finalizer
checks the selected adapter hash, verifies reload decisions, packages under the
3 GB limit, and records a one-time final-test access marker. Real calibration
is still unavailable, so the application requires review for model suggestions.

Progress and local predictions live in `.local/finetune/full-v1`. Completed
aggregate reports and the final summary are copied to `full-results/`; public
checkpoint metrics can be committed at significant improvements. Original probe
measurements remain in `results/` and RESULTS.md.
