# Qwen v2 continuation on Delaware weak labels

Continue the existing v2 step-2,080 adapter, preserving the original checkpoint.
The parent adapter SHA-256 is
`4a46b314239dd384b6d0f57bd6e445a8d4087670d48a87e9ca2e2715adec1e78`.
This resumes adapter weights with a fresh Adam optimizer; no saved optimizer
state exists. Before the first gradient update, the runner verifies every
trainable tensor exactly matches the copied parent checkpoint.

The frozen configuration is [training_config.json](training_config.json).
Train only on the 5,865 accepted Delaware training rows at learning rate 2e-5.
Keep rank 8, the last four adapted layers, batch size 1, accumulation 8, prompt
masking, thinking disabled, and a 512-token limit. One pass rounds up to 5,872
microbatches / 734 optimizer updates, repeating seven training rows to finish
the last accumulation group. No architecture expansion or second pass is planned.

The 672 real validation rows and 279 old synthetic validation rows are evaluation
only. Neither sealed test is opened. The 717 reserved real test rows, old sealed
tests, 100-row exposed diagnostic, rejected rows, and unresolved review conflicts
are never training inputs. Real labels are AI weak labels; the new corpus lacks
Financial and non-spending flows, so old validation regression results matter.

Save continuation checkpoints at microbatches 1,960, 3,920, and 5,872. Evaluate
each on the full new and old validation sets. After all training checkpoints are
saved, reload the frozen parent weights in memory and evaluate the full parent
baseline on those same validation sets. This baseline remains eligible for
selection if continuation does not improve new-validation agreement. Select by
new-validation supported-category macro-F1, exact decision agreement, fewer
invalids, then earlier step; report old-validation regressions separately.
These reference-agreement scores are not human-gold or deployment accuracy.

Outputs stay in `.local/finetune/delaware-v1/`:

- `initial-adapter/`: immutable copied starting weights.
- `adapters/`: all saved continuation weights and native adapter configuration.
- `resume_check.json`: exact warm-start verification before training updates.
- `progress.json`, `events.jsonl`: training/evaluation progress written by the job.
- `watchdog/qwen-delaware.log`: stdout/stderr from the trainer.
- `watchdog/qwen-delaware.json`: final bounded-process result.
- `parent_baseline.json`, `checkpoint-*.json`: validation comparisons.
- `selection.json`, `selected-adapter/`: validation-selected weights, possibly parent.
- `training_report.json`: completed run summary.

The job runs detached with a 12-hour whole-command limit, 18 GB process RSS guard,
14 GB MLX memory limit, and 512 MB cache cap. `caffeinate -i` prevents idle sleep
only while the bounded command is running. There are no automatic restarts,
extra epochs, production replacement, test evaluation, or recurring notifications.
User requested one progress inspection five minutes after launch, then to leave
the job running until they ask about it.

Prepare exactly once with `.venv/bin/python -m scripts.train_delaware_qwen prepare`.
Run the frozen job with `.venv/bin/python -m scripts.train_delaware_qwen train`
through `scripts.run_bounded`; consult `launch.json` before starting anything
because duplicate launches are forbidden.
