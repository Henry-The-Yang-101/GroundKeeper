# Bounded public-data probe — 2026-10-09

This records the completed probe and the proposal before approval. The user
subsequently approved the full run on 2026-10-09. See README.md for its execution
workflow and `full-results/RESULTS.md` once the full run has completed.

The 128-microbatch JSON-output QLoRA probe completed successfully. Category
accuracy on the fixed 116-row synthetic validation set increased from 49.1% to
68.1%; exact agreement on all three fields increased from 44.0% to 57.8%.
These are comparisons with AI-reviewed synthetic labels, not evidence of
accuracy on the user's transactions. Full training has not started.

## Output contract and confidence

The user reaffirmed this output contract after considering a category-only
answer. The probe already used this contract; no category-only run occurred.

```json
{"type":"expense","category":"dining","review":false}
```

Training supervises all three fields. No confidence percentage is generated.
`review` is a policy target for ambiguous or provisional decisions, not a
calibrated probability of correctness. A valid schema does not establish a
correct classification. The runtime currently overrides model suggestions to
`review=true` pending real held-out calibration; the metrics below assess the
model's original three-field suggestion before that override.

The parser accepts plain JSON or one complete Markdown JSON fence, then requires
exact keys, allowed values and type/category consistency. Invalid output becomes
`{"type":"unknown","category":"uncategorized","review":true}`.
Other remains an understood expense outside the taxonomy, not an error bucket.

## Audited dataset

The initial 60 difficult cases were audited before bulk labeling. Luna 6 agents
then labeled 950 rows in packets of 25: 850 US source rows, including 50 from each
of 17 source categories, and 100 authored Canadian diagnostic rows. Packets
009–037 used the requested extra-high effort. The parent made 35 adjudications.
A fresh blind audit agreed on 69 of 75 cases before adjudication; that measures
AI reviewer agreement, not accuracy against independent human labels.

After limiting each merchant group to six variants, 810 rows remained: 717 US
synthetic source rows and 93 authored Canadian synthetic rows. No private or real
transaction was used. No stronger ungated Canadian category source was verified.
Source selection, license checks and rejected alternatives are in AUDIT.md.

| Partition | Rows | Merchant groups |
|---|---:|---:|
| Training | 626 | 399 |
| Validation | 116 | 59 |
| Final category test, not scored | 68 | 45 |

Grouping spans both sources and uses reviewed merchant/parent aliases plus
exact-description unions. Unrecognized relationships remain possible. The
validation set contains 107 US rows and only 9 Canadian diagnostic rows. Gifts
has just one training example; financial, taxes and Other have no validation
support. Per-category counts are in dataset_report.json. The planned real
development/calibration/test corpus and future-known-merchant evaluation are
unavailable. The final category test has not been read by the experiment runner
or used to choose settings.

## Validation comparison

All 116 validation merchant groups are unseen in training. No user-confirmed
merchant aliases exist, so all 116 examples are unresolved by confirmed matching.

| Model | Category accuracy | Type accuracy | Exact three-field accuracy | Macro-F1, supported labels | Invalid schema |
|---|---:|---:|---:|---:|---:|
| Character TF-IDF + logistic regression | 37.1% | 91.4% | 35.3% | 0.394 | N/A: deterministic output |
| Original prompted Qwen3.5-4B | 49.1% | 69.8% | 44.0% | 0.494 | 49/116 |
| Fixed 128-microbatch QLoRA probe | 68.1% | 86.2% | 57.8% | 0.628 | 13/116 |

Macro-F1 averages the 18 labels with validation support, including Uncategorized
and the null-category class where supported. Averaging all 21 category/null
labels, including those with zero support, gives 0.337 / 0.423 / 0.538. Full
per-category precision, recall and support are in results/*_report.json.

The original model fenced all 116 JSON answers. Its initial strict-parser report
rejected all of them. The table uses the SAME saved raw answers rescored with
the shared fence-tolerant strict validator. The original report is retained;
format normalization is not presented as a fine-tuning gain. After normalization,
49 base answers still violated the schema. The probe used no fences, but 10
answers used invalid category values and 3 assigned spending categories to
nonexpense types. All 13 failures fell back to unknown/review.

| Source | Rows | Base category accuracy | Probe category accuracy |
|---|---:|---:|---:|
| US synthetic | 107 | 47.7% | 67.3% |
| Authored Canadian diagnostic | 9 | 66.7% | 77.8% |

The Canadian sample is too small and artificial to establish regional
performance. No real-data scores are available. Automatic model acceptance is
disabled: coverage is zero and accepted-error rate is undefined, not zero.
Mean generation latency was 0.910 seconds for the base and 0.715 seconds for the
probe on this validation set; these are measured local runs, not latency promises.

## Confirmed merchant layer

Implemented rules distinguish transaction-scoped corrections from explicitly
merchant-wide confirmations; public reference pairs never become confirmations.
Matching preserves merchant-discriminating tokens and excludes confirmations
from after the transaction's as-of time. The module receives an already unlocked
database connection and cannot read personal memory while locked.

The separate Crossing Minds identity benchmark contained 3,047 distinct pairs
from 3,111 source rows. A closed-vocabulary fuzzy reference baseline scored 57.8%
top-1 identity accuracy on its 294-row test: 64.6% for 263 seen merchants and 0%
for 31 unseen merchants absent from the vocabulary. No tested threshold/margin
met the validation criterion of at least 20 accepted examples with at most 1%
observed error. Acceptance was disabled; no threshold was deployed. This is a
merchant identity test, not the sealed category test or real calibration.

## Compatibility, throughput and package

The pinned Qwen3.5-4B MLX revision is
`32f3e8ecf65426fc3306969496342d504bfa13f3`. Native text export removes the vision
tensors and preserves the 4-bit affine text weights. Thinking is disabled in
both the saved template and inference. Prompt masking and exact token-prefix
agreement were checked on every training/validation row. Maximum sequence length
was 384 against the limit of 512; no truncation was necessary.

The probe trained 532,480 adapter parameters on the last four layers, with rank
8, scale 2, zero dropout, microbatch 1, accumulation 8, Adam at 5e-5 and gradient
checkpointing. The 128 microbatches are **16 optimizer updates**.

| Measurement | Observed value |
|---|---:|
| Native training time, including sampled validation | 410.85 seconds |
| Whole bounded training process | 415.15 seconds |
| MLX peak allocated memory | 7,854,485,238 bytes |
| Watchdog peak process-tree RSS | 3,686,645,760 bytes |
| Minimum system available memory during probe | 2,529,361,920 bytes |
| Exported base files | 2,387,322,610 bytes |
| Complete probe model package | **2,389,468,179 bytes** |

MLX allocation, process RSS and system headroom are different measurements; none
should be substituted for the others. The model package includes base weights,
adapter, tokenizer, template, configs, policy and manifest and is below the
3,000,000,000-byte limit. Five exact-runtime US/Canadian smoke inputs returned
valid application objects with review required. This checks runtime/schema
behavior, including fallback, not that all five classifications were correct.
The package is experimental and the original base is retained for rollback.

Sampled validation loss fell from 1.733 to 0.225. Each check covered eight
batches, and the native trainer evaluates before the current training step.
Those losses are not full-validation measurements of the numbered saved
checkpoints. The table above independently evaluates the actual final 128-step
adapter. No checkpoint was selected for production.

One reproducibility issue was found after the probe: native `train_model` seeded
MLX adapter initialization, but NumPy batch shuffling was seeded only by its
CLI wrapper, which this harness bypassed. The measured probe's batch order was
therefore unseeded. The harness now explicitly seeds NumPy before training and
records that fact; the original runner, measured reports and exact package hashes
are preserved. The historical probe cannot be regenerated from the seed alone.
Dataset preparation and splits are deterministic. Thirteen meaningful unit tests
pass; the local model load, training, validation and packaged runtime also ran.

## Concrete full-run proposal — approval pending

Use proposed_full_config.json with the same frozen 626-row training set and
116-row validation set, starting from the untouched base. Keep the JSON contract,
rank 8, last four layers, microbatch 1, accumulation 8, length 512, Adam at 5e-5,
gradient checkpointing and prompt masking. Apply both MLX and NumPy seeds.

Run **632 microbatches / 79 optimizer updates**, approximately 1.01 passes over
training data. The extra six microbatches complete the accumulation window;
626 steps would perform only 78 complete updates. The historical probe report's
79-update estimate for exactly 626 steps was a rounded estimate, not an executed
run. The current wrapper reports this distinction explicitly.

Save adapters at 128, 256, 384, 512 and final 632. Training-time eight-batch
validation remains diagnostic. Evaluate each actual saved checkpoint on all 116
validation rows and select highest supported-label macro-F1, breaking ties by
exact three-field accuracy, then fewer invalid outputs, then earlier checkpoint.
The final category test remains sealed until settings and checkpoint are fixed.
No automatic-acceptance calibration can be claimed without real reviewed data.

Measured throughput implies about 33 minutes for training; full validation of
five saved checkpoints adds about 7 minutes. Allow **40–50 minutes overall**,
with a 60-minute whole-run deadline and separate bounded evaluation jobs. Expect
approximately the measured 7.85 GB MLX peak, but retain the existing memory and
system-headroom watchdogs because other applications affect available memory.
Start a deliberate new watchdog session only after confirming no job is active.
Do not extend to multiple epochs without a new validation-based justification.

This is a proposal, not an approved or launched full run. The user's original
plan explicitly requires presenting counts, configuration, measured memory and
runtime for approval before full training. The experiment entry point currently
supports the bounded probe only. No production deployment has occurred.

## Evidence

The results directory contains measured JSON reports, package file hashes,
watchdog measurements, the historical runner, and a manifest binding evidence
to code and input versions. Raw public predictions, local weights and adapters
remain under the ignored `.local/finetune` directory. `collect_probe_results.py`
copies aggregate evidence without opening final category test rows. README.md
contains reproduction commands; uv.lock pins the Python environment.
