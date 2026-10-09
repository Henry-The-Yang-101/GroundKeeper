# Version 2: coverage, label audit and constrained JSON

The user approved coverage repair, label audit, constrained JSON and hours of
local training if useful on 2026-10-09, with scheduled improvement reports.
Commit significant milestones under the user's sole Git identity.

## Immutable comparison

Preserve all v1 data, code paths, reports and packages. Never add v1 validation
or final-test examples, their duplicates, or their merchant groups to training.
V1 validation remains an unchanged regression benchmark. The v1 final test has
already been scored and must not influence further tuning or be scored again.
New v2 held-out data must be separated before model selection and augmentation.

## Finite work plan

1. Blind-audit 75 difficult/rare v1 training labels, 25 per Luna 6 xhigh agent.
   Parent adjudicates against input evidence and freezes written policy additions
   before bulk labeling. Keep original decisions and correction reasons.
2. Implement canonical full-JSON constrained generation locally, with type,
   category and review fields. The finite grammar enforces schema invariants and
   fails closed on truncation or an impossible path. It is not calibrated
   confidence. Test every grammar path and compare the frozen v1 model on the
   unchanged 116-row validation set; never score its final test again.
3. Expand the audited pool toward 3,000–5,000 examples if diversity supports it.
   Use pinned ungated US public synthetic data and clearly identified authored
   US/Canadian coverage examples. Private transactions stay local; no real or
   human-labeled dataset is assumed. Prioritize missing transaction types, rare
   categories, mixed merchants, ambiguity, and type/category boundary examples.
   Every additional source row is blind-labeled in packets of at most 25 using
   Luna 6 xhigh. Independently audit difficult and rare cases. Avoid copying held-
   out merchant-specific errors into training. Stop expanding if variants add
   repetition rather than merchant or purpose diversity; report actual counts.
4. Build v2 with explicit category/type coverage checks, merchant/chain grouping,
   normalized duplicate detection, source provenance, capped variants, and
   separate legacy-validation, new-validation and newly sealed-test partitions.
   Generic purpose is not a merchant identity; preserve independent institutions
   and authored template families instead of merging a whole transaction type
   into one leakage group. Report any unsupported evaluation classes explicitly.
5. Freeze v2 data and compare original base and v1 selected adapter with the same
   constrained decoder on v2 validation. Use type-first targets and align compact
   prompting with the audited policy; verify prompt masking and no truncation.
6. Run at most two primary v2 QLoRA candidates from the untouched quantized base:
   rank 8, last four layers, microbatch 1, accumulation 8, one pass rounded to a
   complete update, learning rates 5e-5 and 2e-5. Compare actual saved checkpoints
   by supported-label macro-F1, then exact three-field accuracy, fewer invalid
   outputs and earlier checkpoint. Evaluate both on identical frozen validation.
   A second epoch is allowed only when validation still improves at the end,
   within the same overall budget. Do not widen ranks/layers in this round.
7. Freeze settings/checkpoint, evaluate the new sealed synthetic test once, verify
   the exact constrained local runtime and a package under 3,000,000,000 bytes,
   and retain v1/base rollback. No automatic acceptance without real calibration.

## Bounds and reporting

Preparation artifacts live in `.local/finetune/v2`; public audit decisions,
scripts and aggregate reports are versioned under this directory. A scheduled
five-minute heartbeat resumes/monitors this work, reports significant preparation
milestones, evaluated gains, completion or failure, and stays quiet otherwise.
Use `.local/finetune/v2/status.json` and `reported_progress.json` for durable state.
Inspect active model processes before each GPU job. GPU jobs run serially.

Constrained validation experiments have a 15-minute per-job limit. Full v2
training has a six-hour overall session limit, at most three hours per candidate,
with measured-time estimates refined after preparation. Keep the 18 GB process
RSS limit, 14 GB MLX allocation limit, 512 MB MLX cache, and available-memory
watchdog. Stop and report if bounds are insufficient; hours are not authorization
for unlimited retries. Delete the heartbeat after final completion or an
unrecoverable failure. Never claim synthetic gains establish real-world accuracy.

## Current state

The 75-row legacy policy audit is complete: one label correction and one
exclusion. The decoder audit found that keeping valid drafts and constraining
invalid retries preserves v1 category accuracy at 69.0%, improves macro-F1 from
0.661 to 0.690, and returns zero invalid answers on the unchanged 116-row
validation set. This is a decoding result, not a newly trained model gain.

All 2,900 new candidates were labeled in 116 blind packets of 25. The independent
150-row audit agreed on 146 initial decisions; all four disagreements were
adjudicated. Additional blind reviews covered 16 duplicate-family cases and 12
related boundary cases. These counts describe reviews, not unique human labels.

The frozen v2 dataset has 2,077 training, 279 new validation and 213 newly sealed
test rows. Training includes 496 CAD and 1,581 USD examples. Every required type
and category coverage gate passes. Merchant/duplicate exclusions and variant
caps take priority over the aspirational 3,000–5,000 example count.

`training_config.json` freezes two one-pass candidates, 2,080 microbatches each,
with saved-checkpoint evaluations at steps 696, 1392 and 2080. Maximum observed
sequence length is 496 tokens; the configured limit is 512 with verified prompt
masking and no truncation. Estimated total runtime is 19,093 seconds (5.3 hours),
under the six-hour outer watchdog limit. See live status and `RUNBOOK.md` before
starting or monitoring; never launch a duplicate pipeline.
