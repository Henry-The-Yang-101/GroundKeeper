# Evidence-aware Qwen training

Run from the repository root with `.venv/bin/python -m scripts.evidence_training`.
These commands create a separate experiment. They never update an installed model.
No training has been started merely by adding these scripts.

## Freeze reviewed data

`freeze` takes final canonical JSONL rows with all of these fields:

```json
{"id":"fixture-1","source":"delaware","merchant_family":"fictional market","split":"train","input":{"description":"Fictional Market","direction":"debit","currency":"USD"},"answer_with_context":{"type":"expense","category":"groceries","review":true},"answer_without_context":{"type":"expense","category":"groceries","review":true},"provenance":{"fixture":true}}
```

Inputs use the current production schema, including the actual captured
`merchant_context` object when available. Labels with and without that context
are distinct. Rows without merchant context must have identical paired targets.
Every row needs a preassigned `train`, `valid`, or `test` split. The required
historical registry is JSONL of `merchant_family` and `split`; callers must supply
the complete registry of previously exposed families. Contradictions inside that
registry, or between old and new families, fail closed. Resolve merchant aliases
and proposed family merges before freezing; splitting never occurs in this tool.

The separate acceptance JSON binds the exact final label file bytes and count:

```json
{"status":"accepted","labels_sha256":"SHA256_OF_FINAL_CANONICAL_JSONL","labels_count":6200,"policy_version":"groundkeeper-19-v2","reviewer":{"model":"gpt-6.1-sol","reasoning_effort":"high"}}
```

The count above is illustrative; use the actual reviewed count. The acceptance
producer is responsible for requiring the intended independent reviews and
internet evidence. A matching hash is an integrity gate, not proof that reviews
were performed. Initial training does not require model predictions or mistake
verdicts. Keep raw labels, reviews, search evidence, and personal rows private.

```sh
.venv/bin/python -m scripts.evidence_training freeze \
  --labels .private/qwen-evidence-v3/reviewed.jsonl \
  --acceptance .private/qwen-evidence-v3/acceptance.json \
  --family-registry .local/finetune/evidence-v3/source/historical_families.jsonl
.venv/bin/python -m scripts.evidence_training preflight
```

The default frozen destination is `.private/qwen-evidence-v3/frozen`; existing
destinations are refused. Freezing reads each split once to validate and seal it.
All later preparation and checkpoint selection read only train and validation
payloads plus the ID/family split ledger. Test payloads stay sealed. Final held-out scoring requires the explicit immutable selection lock described below.

Preflight verifies the original local base weight hash
`d58b87def677c7b3235e21cdca85289a162a5ba8949687b9573592e3c74cd477`.
It loads the real tokenizer, checks the assistant-only prefix and each production
input cap, and refuses any row that would need truncation or web-evidence
shrinking. The maximum sequence is 3072 input tokens plus the grammar's maximum
answer token count and two stop-token slots. The checked base, code, data,
acceptance, dependency versions, and config are then bound by hashes.

`preflight --deployment-inputs-only` fits each actual production input once,
including its captured `merchant_context`, and omits the additional context-free
training view. Genuine no-match or withheld-query inputs remain unchanged.
Evaluation still reports both views. This mode is recorded in the frozen config.

## Train and compare

```sh
.venv/bin/python -m scripts.evidence_training train \
  --qwen-baseline PATH_TO_EXISTING_QWEN_WORKER_PACKAGE \
  --delaware-baseline PATH_TO_EXISTING_QWEN_DELAWARE_WORKER_PACKAGE
```

The two baselines run serially before training using their unchanged weights.
`train --baseline-timing after` (also supported by `cycle`) instead fits first,
releases training objects, and scores both baselines before selecting a checkpoint.
Each has two comparisons: a controlled current-v2-prompt weights comparison, and
its configured package prompt under the current Worker. Reports identify both
prompt versions so adapter and prompt changes are distinguishable. The new run loads the original base with
no resumed adapter or optimizer. Starting settings are rank 8 in the last four
layers, learning rate `1e-5`, batch size 1, accumulation 8, seed 20261028, and
assistant-only loss. Each train row contributes its context input and, if web
context exists, a second context-free view. The run uses one pass through those
expanded examples, rounded up to an accumulation boundary. Rounding may repeat
up to seven examples through the MLX dataset iterator.

Training recomputes the gated-delta recurrence in 32-token chunks to bound
backpropagation memory. State and its gradients carry across every boundary;
there is no sequence truncation or detached history. The wrapper is scoped to
training and restores the installed MLX function afterward. Numerical tests compare
outputs and gradients with the original recurrence. Reports are appended to
`training/loss-reports.jsonl` every eight microbatches. Keep the external memory
watchdog enabled, and preserve failed attempts before a deliberate fresh retry.

Three saved checkpoints are evaluated serially through the actual production
`Worker.classify`/`Worker.qwen` path. Worker forces `review=true` on returned decisions. Reports distinguish raw model
review accuracy from deployed review accuracy. The primary decision metric is
`type_category_accuracy`, which excludes that forced review flag. Selection uses
macro F1 on supported categories, then type/category accuracy, fewer invalid
outputs, and earlier step. Three-field joint accuracy is diagnostic only. Baseline metrics are reported;
there is no assumed improvement threshold or automatic promotion. Per-example
predictions remain private; local run reports contain hashes and aggregate
metrics. Existing run paths are refused, including incomplete runs.

```sh
.venv/bin/python -m scripts.evidence_training predict \
  --package-path PATH_TO_WORKER_PACKAGE --split train \
  --output .private/qwen-evidence-v3/predictions/review-train.jsonl
.venv/bin/python -m scripts.evidence_training lock \
  --selection .local/finetune/evidence-v3/training/selection.json
.venv/bin/python -m scripts.evidence_training package \
  --checkpoint .local/finetune/evidence-v3/training/adapters/SELECTED_STEP_adapters.safetensors \
  --adapter-config .local/finetune/evidence-v3/training/adapters/adapter_config.json
```

Packaging requires an immutable lock for the checkpoint recorded in the frozen
run's validation selection, verifies its hash, and builds a new Worker-verified package under
`.local/finetune/evidence-v3/package`. It copies base files and the selected
adapter and never installs them. `predict` supports train and validation only.

## Prepare reviewed mistake replay

`replay` emits a separately reviewed TRAIN replay dataset. `cycle` performs the
subsequent training pass from a specified locked parent checkpoint, with a fresh
optimizer and all original base/data/policy bindings preserved. Each verdict needs `id`, `variant` (`with_context` or
`without_context`), `verdict: "label_confirmed_model_wrong"`, `prediction_sha256`,
`input_sha256`, `model_sha256`, `answer_sha256`, and
`reviewer: {"model":"gpt-6.1-sol","reasoning_effort":"high"}`. All hashes must
match the saved per-row prediction and frozen input/target. Validation or test
rows, duplicate verdicts, stale predictions, and label disagreements are rejected.
The reviewer must independently establish the verdict; prediction disagreement
alone does not qualify a row.

```sh
.venv/bin/python -m scripts.evidence_training replay \
  --predictions .private/qwen-evidence-v3/predictions/review-train.jsonl \
  --verdicts .private/qwen-evidence-v3/predictions/review-verdicts.jsonl \
  --output .private/qwen-evidence-v3/replay/train-reviewed.jsonl
```

To train the next cycle, use TRAIN predictions from the selected packaged parent.
The model hash in each prediction must match the parent adapter checkpoint hash.
The correction cycle keeps the full original training set and adds exactly one
copy of each independently confirmed mistake view. It never trains on validation
or held-out corrections. Each cycle gets a new output directory and a frozen
cycle configuration; it saves/evaluates three checkpoints using validation only.
Automatic cycle scheduling, automatic relabeling, and production promotion are
not implemented.

```sh
.venv/bin/python -m scripts.evidence_training cycle \
  --cycle-name reviewed-1 \
  --parent-selection .local/finetune/evidence-v3/training/selection.json \
  --replay-predictions .private/qwen-evidence-v3/predictions/review-train.jsonl \
  --replay-verdicts .private/qwen-evidence-v3/predictions/review-verdicts.jsonl \
  --qwen-baseline PATH_TO_EXISTING_QWEN_WORKER_PACKAGE \
  --delaware-baseline PATH_TO_EXISTING_QWEN_DELAWARE_WORKER_PACKAGE
```

Lock a later cycle by passing its `cycles/NAME/selection.json` to `lock` and to
`package --selection`. Locks are created exclusively and cannot be replaced.
Packaging still needs that cycle's adapter config and selected checkpoint.

## Final held-out comparison

After the final selection is locked and packaged, run:

```sh
.venv/bin/python -m scripts.evidence_training final-score \
  --selection .local/finetune/evidence-v3/training/selection.json \
  --package-path .local/finetune/evidence-v3/package \
  --qwen-baseline PATH_TO_EXISTING_QWEN_WORKER_PACKAGE \
  --delaware-baseline PATH_TO_EXISTING_QWEN_DELAWARE_WORKER_PACKAGE
```

This verifies the selection lock, selected adapter in the package, all baseline
packages, and frozen data. It creates `frozen/test-access.json` exclusively before
opening the held-out payload, then evaluates the candidate and both baseline
prompt variants once. The marker blocks further training, correction cycles,
preflight, and new selection locks on that corpus. Failed final scoring also
consumes this access; do not remove the marker to resume optimization. A failed
final result requires a newly reserved untouched holdout before further model
selection.

The final aggregate report includes overall, source, and context-view accuracy
and macro F1 deltas, invalid output counts, observed regressions, and paired 95%
bootstrap confidence intervals clustered by merchant family so repeated
transactions and context variants stay together. The actual captured-input
`with_context` cohort is primary; all-view averages are secondary. Reports also
include source-by-variant cohorts, matched versus fallback context cohorts,
per-category support/recall, specific-suggestion coverage/error, and annotated
Other reasons when supplied in provenance. Each source, including the personal source, gets its own report.
The report records the 10 percentage point improvement ambition without silently
changing model selection or claiming success. These intervals quantify sampled
row uncertainty; independent weak-label quality is a separate limitation.
