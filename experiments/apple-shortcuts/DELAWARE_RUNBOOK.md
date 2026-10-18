# Delaware Apple Cloud benchmark

The first quota-limited result is documented in
[DELAWARE_RESULTS_2026-10-17.md](DELAWARE_RESULTS_2026-10-17.md).

Cloud with Broad World Knowledge enabled was verified in the live **GK
Categorize Cloud** Shortcut on 2026-10-17. Text output, Follow Up off, and the
existing `prompt.txt` are unchanged. No benchmark-driven prompt tuning is used.

The evaluation uses the **672 validation rows** in the new Delaware labeled
dataset, rather than its training set or sealed test. The descriptions are exact
public institutional card merchant strings; the reference decisions are AI weak
labels, with zero human-confirmed labels. Scores measure reference agreement,
not human-verified real-world accuracy. Only description, unknown direction,
and null currency enter inference. Answers, merchant families, source metadata,
audits and evidence are never sent to Apple.

```sh
.venv/bin/python -m scripts.benchmark_apple_shortcuts \
  --dataset .local/delaware-labeling-v1/prepared/valid.canonical.jsonl \
  --config experiments/apple-shortcuts/config.json \
  --output .local/apple-shortcuts/delaware-cloud-world-20261017-v1 \
  --order-seed 20261017 --limit 672 --timeout 60 \
  --session-seconds 3600 --interval 1
```

Rows are ordered by SHA-256 of seed and row ID, independently of labels. The
fixed shuffled order reduces file-order bias if Apple's quota stops the run,
but the underlying dataset remains a merchant-diverse selection, not a uniform
sample of all Delaware transactions or personal bank transactions.

The same command resumes completed work without repeating predictions. Inspect
active processes before launching; never run duplicate workers against the same
directory. Each response is saved immediately. Service failures stop the run;
there are no automatic quota retries or scheduled follow-ups. Invalid decision
schemas score zero on every accuracy field. Reports include metrics over all
completed outputs, with invalid categories treated as incorrect, and separately
identify valid-output-only metrics. Partial runs are labeled partial/stopped.

No saved Qwen comparison is loaded for this new dataset. Earlier scores on
different examples must not be presented as a same-set baseline.

The initial run was paused after 10 successful predictions to repair a scorer
test failure involving invalid-output sentinels and Boolean review values.
No inference setting, input, reference label, row order or prediction was changed;
all 10 responses are reused. The corrected four-test adapter/scorer suite passed
before resuming.
