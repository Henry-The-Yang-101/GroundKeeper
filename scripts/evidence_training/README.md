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
payloads plus the ID/family split ledger. Test payloads stay sealed. This tool
does not yet implement final held-out reporting after selection is permanently
locked.

Preflight verifies the original local base weight hash
`d58b87def677c7b3235e21cdca85289a162a5ba8949687b9573592e3c74cd477`.
It loads the real tokenizer, checks the assistant-only prefix and each production
input cap, and refuses any row that would need truncation or web-evidence
shrinking. The maximum sequence is 3072 input tokens plus the grammar's maximum
answer token count and two stop-token slots. The checked base, code, data,
acceptance, dependency versions, and config are then bound by hashes.

## Train and compare

```sh
.venv/bin/python -m scripts.evidence_training train \
  --qwen-baseline PATH_TO_EXISTING_QWEN_WORKER_PACKAGE \
  --delaware-baseline PATH_TO_EXISTING_QWEN_DELAWARE_WORKER_PACKAGE
```

The two baselines run serially before training under the current policy and v2
prompt, using their unchanged weights. The new run loads the original base with
no resumed adapter or optimizer. Starting settings are rank 8 in the last four
layers, learning rate `1e-5`, batch size 1, accumulation 8, seed 20261028, and
assistant-only loss. Each train row contributes its context input and, if web
context exists, a second context-free view. The run uses one pass through those
expanded examples, rounded up to an accumulation boundary. Rounding may repeat
up to seven examples through the MLX dataset iterator.

Three saved checkpoints are evaluated serially through the actual production
`Worker.classify`/`Worker.qwen` path. Worker forces `review=true` on returned
decisions, so reported review and joint accuracy include that deployed behavior.
The validation metric comparison is macro F1 on supported categories, then joint
accuracy, fewer invalid outputs, and earlier step. Baseline metrics are reported;
there is no assumed improvement threshold or automatic promotion. Per-example
predictions remain private; local run reports contain hashes and aggregate
metrics. Existing run paths are refused, including incomplete runs.

```sh
.venv/bin/python -m scripts.evidence_training predict \
  --package-path PATH_TO_WORKER_PACKAGE --split train \
  --output .private/qwen-evidence-v3/predictions/review-train.jsonl
.venv/bin/python -m scripts.evidence_training package \
  --checkpoint .local/finetune/evidence-v3/training/adapters/SELECTED_STEP_adapters.safetensors \
  --adapter-config .local/finetune/evidence-v3/training/adapters/adapter_config.json
```

Packaging requires the checkpoint recorded in the frozen run's validation
selection, verifies its hash, and builds a new Worker-verified package under
`.local/finetune/evidence-v3/package`. It copies base files and the selected
adapter and never installs them. `predict` supports train and validation only.

## Prepare reviewed mistake replay

`replay` only emits a separately reviewed TRAIN replay dataset. It does not start
a later training cycle. Each verdict needs `id`, `variant` (`with_context` or
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

No replay training command, automatic relabeling, multi-cycle search, source/private
regression gate, or held-out final scoring is implemented by this initial driver.
Those steps require separately frozen cycle configuration and evaluation plans.
