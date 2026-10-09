# Apple Cloud versus Qwen: partial validation

Measured 2026-10-09 through the edited **GK Categorize Cloud** Shortcut on macOS
27.0, with **Broad World Knowledge on**, **Follow Up off**, and **Text** output.
Each request supplied only description, direction and currency. Responses were
parsed using the existing three-field GroundKeeper validator. The experiment
did not access final-test data or send private bank transactions.

## Measured comparison

Apple returned valid predictions for **138 of the planned 279 validation rows**.
On the next row it returned:

> Error: You have reached the usage limit for this model. Please try again later.

The run stopped immediately and preserved all responses. There were **zero
invalid outputs** among completed requests and **one service failure**. The
partial benchmark took 332.2 seconds including intentional one-second pauses;
successful requests averaged **1.392 seconds** (median 1.326).

Both columns below use **exactly the same 138 row IDs**. Qwen results are the
saved v2 candidate-0 step-2080 predictions, not a new inference run.

| Metric | Apple Cloud + world knowledge | Qwen v2 |
| --- | ---: | ---: |
| Category agreement | 104/138 (75.4%) | 105/138 (76.1%) |
| Transaction type agreement | 114/138 (82.6%) | 128/138 (92.8%) |
| Review flag agreement | 101/138 (73.2%) | 111/138 (80.4%) |
| Exact three-field agreement | 85/138 (61.6%) | 98/138 (71.0%) |
| Supported-category macro-F1 | 0.750 | 0.759 |
| Invalid JSON | 0 | 0 |

Apple got the category right where Qwen was wrong on 19 rows; Qwen alone was
right on 20. For the complete three-field decision, Apple alone was right on
13 rows and Qwen alone on 26. This partial measurement shows similar category
agreement, with Qwen ahead on transaction types and exact structured decisions.
It does not establish an accuracy advantage for replacing Qwen with Apple Cloud.

## Limits on interpretation

These are agreement scores against public synthetic/authored weak labels,
not verified accuracy on real Canadian bank transactions. The completed subset
is the **first 138 rows in fixed dataset order**, containing 129 public US
synthetic rows and nine authored bank-coverage rows. It is source-imbalanced
and does not represent the complete validation distribution.

Qwen's previously reported **82.1% category agreement on all 279 rows** is not
the appropriate direct comparison with Apple's 75.4% on this subset. Full-set
Apple accuracy remains unknown. No settings or labels were tuned using these
results. Semantic `review` values were scored before the application wrapper
forces `review=true`, just as the local application runtime does.

Two Cloud Pro smoke requests failed with `Too many incoming requests`. Cloud
then succeeded for two smoke requests and 138 benchmark requests before its
explicit quota error: **140 successful Cloud calls observed in this task**.
This is not a numerical daily quota: prior/shared usage, caching, request cost,
and reset timing are unknown. The observation supports Cloud being available
when Pro was unavailable in this session; it does not prove different published
usage limits or that the next session will have the same allowance.

## Resume the remaining rows

After Apple permits requests again, first check that no other benchmark process
is active, then run:

```sh
.venv/bin/python -m scripts.benchmark_apple_shortcuts \
  --output .local/apple-shortcuts/cloud-world-v1 \
  --limit 279 --timeout 60 --session-seconds 1800 --interval 1
```

The command skips all completed examples and resumes at the failed row. Keep
the live Shortcut identical to the saved export. Do not change the model,
prompt or world-knowledge setting while resuming this measurement. No automatic
retries or scheduled follow-up were created.

Evidence: `cloud-world-v1/manifest.json`, `responses.jsonl`, and `report.json`,
plus the signed Shortcut export and `prompt.txt`. Reports were independently
recomputed from saved responses, and every successful raw response was reparsed
and matched to its stored prediction. The three adapter/benchmark tests passed.
The live input/output call worked while the Mac was unlocked; locked-screen
and launchd execution remain untested.
