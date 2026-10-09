# Continue the approved v2 experiment

The user has authorized preparation and longer local training. Do not request
the same permission again. Preserve v1 and use the configured Git identity as
the sole author. Never run the old final test or select settings from new final
test results. All labels/data remain synthetic and AI-reviewed.

## Current work

`/root/v2_bulk_coordinator` orchestrates 116 fresh Luna 6 xhigh labelers, at most
two active at once and exactly one packet of 25 per labeler. It writes
`.local/finetune/v2/labeling_status.json` and `labels/batch_NNN.jsonl`.
Inspect existing agents/files before resuming; do not duplicate active packets.
The 75-row legacy training audit is complete, with one correction and one
exclusion. The JSON decoder audit is in `DECODER_AUDIT.md`.

Preparation is complete. The frozen data has 2,077 training rows, 279 validation
rows and 213 new sealed-test rows. All coverage gates passed. The 150-row audit
and additional 16-row/12-row consistency reviews are committed. All training
and validation token/mask checks passed (maximum 496, configured limit 512).
The commands below document reconstruction, not permission to overwrite frozen
artifacts. Check live pipeline/watchdog state before acting.

## Finish preparation

1. Wait until all 116 label packets are structurally validated. Review canonical
   merchant groups/aliases against the v1 split manifest before freezing; names
   from the old test manifest are exclusion metadata, not new evaluation data.
   If a newly recognized alias joins prior training to a proposed holdout,
   exclude the conflicting component rather than move learned evidence into
   evaluation. The draft report records these exclusions.
2. Run `.venv/bin/python -m scripts.prepare_v2_training --draft`. It reads no v1
   final-test records. Resolve any inconsistent duplicate labels with explicit
   input-based audit decisions before continuing. Do not silently relax gates.
3. Run `.venv/bin/python -m scripts.prepare_v2_audit`. Dispatch the six
   `.local/finetune/v2/new-audit/packet_NN.jsonl` files to six fresh Luna 6 xhigh
   agents, one 25-row packet each. They read `LABELING_POLICY.md` and
   `POLICY_ADDITIONS.md` and emit the same seven-field annotation schema to
   `packet_NN_labels.jsonl`, never reading the first labels. Keep audit jobs
   within available slots; do not ask the bulk coordinator to label itself.
4. Run `.venv/bin/python -m scripts.summarize_v2_audit`. Parent adjudicates every
   disagreement against the source input and policy. Save
   `experiments/finetune/v2/new_label_audit.json` with `complete: true`, the exact
   `reviewed_ids`, `decisions` mapping each disagreement ID to an explicit
   `answer` or `reject: true` and `reason`, and an identical `adjudications` map.
   Retaining the original label still requires a reason. Copy all six audit
   annotation files into the public audit directory. This is AI review, not a
   claim of human annotation.
5. Run `.venv/bin/python -m scripts.prepare_v2_training`. Freezing requires the
   actual six audit files and resolved disagreements. Check merchant/duplicate
   separation, provenance, and coverage: train at least 24 per transaction type
   and 25 per category; new validation/test at least four per type and two per
   category. If a gate fails, add focused blind-reviewed examples through an
   explicitly versioned supplement, or report insufficient coverage; do not
   bypass the gate. Existing candidate/label files are immutable.
6. Run `.venv/bin/python -m scripts.preflight_v2`. It verifies every training and
   validation mask/length and writes the immutable actual-count training config.
   It does not load a model or read test examples. Review the time estimate.
   Commit the complete audit, data report/manifest and frozen configuration.

## Train and monitor

Run the test suite once after the final preparation edits. Inspect
`.venv/bin/python -m scripts.v2_status` and active process arguments locally to
ensure no other model job is running. Do not include unrelated process lists
in public artifacts. Launch exactly one pipeline, from the repository root:

```sh
caffeinate -i .venv/bin/python -m scripts.run_bounded \
  --runs-dir .local/finetune/v2/training-runs \
  --overall-seconds 21600 --seconds 21600 --label v2-full \
  -- .venv/bin/python -m scripts.v2_pipeline
```

Use an exec session that can be polled, or a detached process with a durable log;
do not block the user for six hours. The pipeline refuses a second start. It
serially evaluates base and v1 baselines, trains two one-pass rank-8 candidates
at 5e-5 and 2e-5 with three saved checkpoints each, selects using new validation,
reloads the copied package runtime/weights, and evaluates only the newly sealed
test once. Candidate timeout is three hours; entire watchdog session six hours.
No second epoch is currently configured. Do not alter a live configuration.

For notifications compare the same validation partition, prompt and decoder;
also report legacy validation separately. State category accuracy and macro-F1
separately, exact three-field accuracy and invalid count. Lower loss alone is
not an accuracy improvement. Record notifications in
`.local/finetune/v2/reported_progress.json`; commit aggregate improvements.
`groundkeeper-v2-improvements` is the active five-minute heartbeat.

## Completion and failure

After successful completion, confirm the outer watchdog exit, completed pipeline,
selected adapter hash, package below 3,000,000,000 bytes, copied-runtime reload
checks, and exactly one `final_test_started.json` / final-test report. Copy the
final pipeline and sanitized watchdog evidence into `v2/results`; the finalizer
copies reports before the outer process exits, so its pipeline copy can be stale.
Record total runtime, memory, baseline comparisons, class/regional limitations,
and absent real calibration. All model suggestions require review. Commit the
final reports, notify the user, delete the heartbeat, and keep this chat open.

On failure inspect the saved error. Do not silently restart/overwrite a partial
candidate, package or final-test run. Preserve evidence and report any necessary
change. An unrecoverable failure ends the heartbeat after the user is notified.
