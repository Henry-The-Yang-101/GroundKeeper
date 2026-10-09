# GroundKeeper Laya benchmark and supervised fine-tune

The user authorized benchmarking original Laya and then local fine-tuning on
2026-10-09. This is a synthetic-data experiment, not production deployment.

Use the isolated `.local/laya/.venv` Python environment. The existing Qwen
environment, models, adapters, data, and test sets are preserved. Dependencies
are pinned in `requirements.lock`; the English checkpoint is
`convaiinnovations/laya@55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851`.

The original download is immutable under `.local/laya/base-original`; a separate
prepared copy contains the tokenizer compatibility change needed by Transformers.
Only English checkpoint weights/config/tokenizer files were downloaded, without
the bundled multilingual or typed-decisions models. All inference/training runs
offline on PyTorch MPS, with CPU fallback rejected by placement checks.

## Data and output

Reuse the frozen Qwen v2 splits: 2,077 training transactions and 279 validation
transactions. Each transaction supplies three typed-choice questions, so training
has 6,231 decision items. The model sees only description, direction and currency;
source labels, merchant group, provenance and explanations never become inputs.
All source labels are synthetic and AI-reviewed, not human ground truth.

The 213-row sealed test and previous final tests are never opened by this
experiment. Merchant-group separation and source-file hashes are checked before
conversion; subsequent phases verify source/prepared/model hashes. No splits are
rebuilt or retried. Maximum observed sequence length is 309 tokens under a
512-token limit. All instructions, options and states fit without truncation.

The model predicts type (9 options), category (21 including a null sentinel), and
review (2). Joint decoding maximizes the product of the distributions over objects
allowed by the existing GroundKeeper JSON schema. This constrains type/category/
review consistency; it is not calibrated confidence or an accuracy guarantee.
Reports separately retain independent-head field accuracy, inconsistent raw
combinations and changes made by constrained decoding. Malformed distributions
fail closed to unknown/uncategorized/review.

Base and trained weights use the same questions, fp32 inference, neutral
temperature 1, and constrained decoder. Base shipped temperatures are not used
for this uncalibrated task. The original 21-option bucket is outside upstream's
supported temperature range; no automatic acceptance threshold is derived from it.
`LocalLayaCategorizer.suggest` always requires application review.

## Reproduce and monitor

Never rerun a completed phase into its existing directory. Preparation,
benchmark, probe and training refuse duplicate artifacts. Check
`.local/laya/status.json`, active processes and watchdog logs first. GPU jobs run
serially. Use a new versioned experiment directory for a different candidate.

```sh
uv venv --python .venv/bin/python .local/laya/.venv
uv pip install --python .local/laya/.venv/bin/python -r experiments/laya/requirements.lock
.local/laya/.venv/bin/python -m scripts.laya_experiment prepare
.local/laya/.venv/bin/python -m scripts.run_bounded --runs-dir .local/laya/setup-runs --overall-seconds 3600 --seconds 900 --label baseline -- .local/laya/.venv/bin/python -m scripts.laya_experiment baseline
.local/laya/.venv/bin/python -m scripts.run_bounded --runs-dir .local/laya/setup-runs --overall-seconds 3600 --seconds 900 --label probe -- .local/laya/.venv/bin/python -m scripts.laya_experiment probe
```

The setup session has a one-hour outer bound and 15-minute model jobs. The full
training configuration is frozen only after the measured compatibility probe.
Full training starts again from original prepared base weights, not probe weights.
Use upstream's supervised `soft-ce` objective with option-order augmentation,
activation checkpointing, microbatch 2 and accumulation 16 (effective 32 decision
items). No validation rows train the model or fit confidence temperatures.

Select by validation supported-category macro-F1, then exact three-field
accuracy, fewer invalid outputs and earlier epoch. At most four epochs and
patience two; use a six-hour outer watchdog with existing 18 GB process RSS and
available-memory limits. Save the best full fp32 checkpoint, then verify the
packaged code/weights on validation. A package must stay below 3,000,000,000 bytes.
No recurring monitor is created. Training logs/status remain local.

Upstream references: [Laya 0.4.1](https://pypi.org/project/laya/0.4.1/),
[training implementation](https://github.com/NandhaKishorM/laya/blob/v0.4.1/laya/train.py),
[small-dataset training diagnostics](https://github.com/NandhaKishorM/laya/issues/963).
