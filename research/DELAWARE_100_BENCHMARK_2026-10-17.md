# Delaware 100-transaction diagnostic — 2026-10-17

Qwen v2 matched **54/100** reference categories; Laya matched **39/100**.
References are one Codex reviewer's row-by-row AI judgments, frozen before
inference, **not independent human ground truth**. Neither model was trained,
tuned, or selected using this sample.

## Measured results

| Metric | Qwen v2, step 2,080 | Laya, selected epoch 3 |
| --- | ---: | ---: |
| Category matches, all 100 | 54/100 (54%) | 39/100 (39%) |
| Category matches, 63 high-certainty references | 44/63 (69.8%) | 25/63 (39.7%) |
| Complete type/category/review match | 29/100 | 33/100 |
| Transaction type matches | 68/100 | 91/100 |
| Review-flag matches | 53/100 | 61/100 |
| Supported-category macro-F1 | 0.538 | 0.305 |
| Other recall | 0/7 | 0/7 |
| Category matches after exact-description deduplication | 53/96 (55.2%) | 39/96 (40.6%) |
| Invalid constrained outputs | 0 | 0 |
| Mean inference wall time per transaction, excluding model load | 0.877 s | 0.179 s |

Category results were paired: both matched on 29 rows, only Qwen matched on 25,
only Laya matched on 10, and neither matched on 36. The approximate 95% Wilson
intervals are 44.3–63.4% for Qwen and 30.0–48.8% for Laya. These intervals treat
rows as independent and do not account for shared merchant families, uncertain
references, or disagreement between human reviewers.

Laya's slightly higher complete-decision score comes with better review-flag
behavior, despite its lower category score. Type accuracy is particularly weak
evidence of generalization here: 98 reference decisions are expenses and only
two have unknown type. No income, loan, refund, or transfer performance can be
established from this sample.

## Row-by-row review findings

- Both failed all seven reference Other cases, including the five marked high
  certainty before inference. Standalone postal/courier and background-screening
  services exposed this boundary again. Two Other judgments were explicitly
  less certain and need human adjudication.
- Both failed all seven compressed office-supplier descriptors. This suggests a
  genuine abbreviation/reference-format gap, not merely unfamiliar long-tail
  merchants. No cleaning or augmentation was introduced during this run.
- Qwen matched categories for many recognizable restaurants, vehicle-parts
  merchants, and digital services. It also confused recognizable service
  providers with insurance and often failed to identify a known hotel chain.
- Laya produced more category substitutions even on explicit service cues,
  including accounting software to groceries and some catering to education.
- All 14 sampled mixed-retail entries required review under the frozen policy.
  Qwen set review=true on only 1/14; Laya did so on 14/14. This explains part of
  the difference between category accuracy and complete-decision accuracy.
- There were 13 category errors with review=false for Qwen and 29 for Laya.
  This is descriptive model behavior, not a calibrated-confidence measurement.
  The application still requires review for every suggestion.

Detailed inputs, both predictions, original reference decisions, evidence and
reference-certainty flags are in the ignored local review artifact:

`.local/real-eval/delaware-100-20261017-v1/review.md`

Raw records and row-level labels were not committed to Git. The compact public
aggregate is [DELAWARE_100_RESULTS_2026-10-17.json](DELAWARE_100_RESULTS_2026-10-17.json).

## Sampling and reference procedure

Source: [Delaware State Employee Credit Card Transactions](https://data.delaware.gov/Government-and-Finance/State-Employee-Credit-Card-Transactions/nurt-5rqw),
official API dataset `nurt-5rqw`. The queried population was 2,251,316 rows across
the full published history, not just the recent-years slice.

1. Python's `random.Random(20261017).sample(range(2251316), 100)` selected 100
   transaction offsets without replacement. Each was fetched using a stable
   `:id` ordering, with a unique source row identifier recorded locally. No
   category stratification, keyword filtering, or replacement of difficult rows.
2. Source `rowsUpdatedAt` and total row count matched before and after sampling.
   The frozen sample has 96 distinct descriptions; repeated descriptions remain
   in the primary transaction-weighted metric. Distinct descriptions do not
   establish distinct merchant families.
3. Only the published merchant field was used as `description`, preserving case,
   punctuation, whitespace and reference numbers. `direction=unknown` and
   `currency=null` for both models. Amounts, dates, agencies, merchant categories,
   source identifiers and reference evidence were not model inputs. Source
   category labels were not requested for reference annotation.
4. The reviewer read four blind packets of 25, applying
   `experiments/finetune/LABELING_POLICY.md`, its v2 additions and the taxonomy.
   Every row has a full expected type/category/review decision and evidence.
   Identical inputs were mechanically checked for identical reference answers.
5. Reference certainty was recorded before predictions: 63 high, 32 moderate,
   five low. The original reference file was hashed and frozen before either
   inference run. Scores were not improved by changing references after seeing
   model outputs. The high-certainty slice is supplementary; all 100 rows remain
   in the primary score.
6. Both models ran offline, serially, with their existing prompts and constrained
   decoders. Every sampled row completed, and both outputs were inspected
   against the original references in packets of 25.

## Models and execution integrity

Qwen used the completed v2 adapter
`.local/finetune/v2/training/candidate-0/adapters/0002080_adapters.safetensors`
with the existing local `qwen35-text` base, v2 prompt and constrained decoder.
This is the best of the three completed checkpoints from the existing first
learning-rate run; it is not a claim that the unrun lower-rate comparison or
overall v2 selection pipeline completed. A separate 2 MB adapter copy supplied
the loader's required filename without changing the original checkpoint.

Laya used `.local/laya/package`, selected epoch 3, fp32 MPS inference and its
existing joint constrained decoder. Weight, configuration, tokenizer vocabulary
and packaged runtime hashes were checked. The initial preflight stopped on one
tokenizer-config hash mismatch before producing predictions. Investigation
showed the packager recorded hashes before its own runtime reload, during which
upstream Laya performs its tokenizer compatibility rewrite. The harness verified
the exact transformation against the unchanged selected checkpoint: change
`TokenizersBackend` to `PreTrainedTokenizerFast`, remove `backend` and `is_local`,
and preserve every other value. All other packaged hashes matched. No model or
tokenizer content was edited for this benchmark.

Both inference runs completed under the existing time/memory watchdog. Qwen took
about 91 seconds including loading; Laya about 24 seconds. The script and exact
artifact hashes are retained for audit. No package, prompt, training data,
training configuration, existing validation data, or sealed test was changed.

## Interpretation and next boundary

Qwen is stronger for category selection on this diagnostic; Laya is faster and
better on mixed-retail review flags. Both show substantial weaknesses on actual
merchant descriptors. The scores are conditional on this input-only contract,
institutional-card distribution, category policy and one AI reviewer. Missing
direction/currency context can affect outputs; these are not end-to-end personal
banking accuracy estimates.

The difference from synthetic validation is evidence of a possible distribution
gap, not proof of synthetic memorization: category composition, merchant
coverage, format and available context all differ. Human review of the 37 less
certain references is the next prerequisite for stronger accuracy claims.

This sample remains outside training. Because its results have now been
inspected, treat it as an exposed diagnostic/development benchmark, not a sealed
final evaluation set or a source of examples to copy into training. A separate
merchant-family-held-out real test set is still required. No training or tuning
was started.
