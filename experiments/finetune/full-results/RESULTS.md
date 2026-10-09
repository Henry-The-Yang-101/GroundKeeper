# Full JSON-output training results

Completed the approved 632-microbatch / 79-update run on 626 AI-reviewed synthetic training rows.
Selection uses only 116 validation examples. No real transaction calibration is available.

| Model on the same validation set | Category accuracy | Macro-F1 | Exact three-field accuracy | Invalid outputs |
|---|---:|---:|---:|---:|
| Original prompted base | 49.1% | 0.494 | 44.0% | 49/116 |
| Earlier bounded probe | 68.1% | 0.628 | 57.8% | 13/116 |
| Selected full-run checkpoint 512 | **69.0%** | **0.661** | **62.9%** | **10/116** |

The selected model gained 19.8 percentage points in category accuracy over the
base and 0.9 points over the probe. Exact three-field agreement gained 5.2 points
over the probe. These small validation improvements do not establish a reliable
population-level advantage. The base uses the same strict schema with whole
JSON-fence normalization, as documented in the earlier probe report.

| Checkpoint | Category accuracy | Macro-F1 | Exact JSON decision accuracy | Invalid outputs |
|---|---:|---:|---:|---:|
| 128 | 69.0% | 0.652 | 58.6% | 12/116 |
| 256 | 63.8% | 0.630 | 56.9% | 9/116 |
| 384 | 66.4% | 0.636 | 59.5% | 8/116 |
| 512 | 69.0% | 0.661 | 62.9% | 10/116 |
| 632 | 66.4% | 0.631 | 60.3% | 9/116 |

Selected checkpoint: **512**, using the predeclared macro-F1/tie-break rule.

The final synthetic test was evaluated once after freezing selection: n=68, category accuracy 60.3%, supported-label macro-F1 0.532, exact three-field accuracy 60.3%. This is not a second validation score or real-world accuracy estimate.

That is 41/68 correct category decisions, with two invalid model answers handled
by the unknown/review fallback. The final test score was not used to change the
selected checkpoint or launch another run. Supported-label macro-F1 covers 18
labels in validation and 16 in the final test, so its averaging set differs.

| Source | Validation rows | Selected validation category accuracy | Final test rows | Final test category accuracy |
|---|---:|---:|---:|---:|
| US synthetic source | 107 | 68.2% | 57 | 57.9% |
| Authored Canadian diagnostic | 9 | 77.8% | 11 | 72.7% |

The Canadian examples are authored synthetic diagnostics, not real bank records;
the small counts cannot establish regional performance. Financial, taxes and
Other have no validation support. Vehicle, software, financial, taxes and gifts
have no final-test support. Gifts has only one training example. No human-labeled
or real-transaction evaluation corpus was available.

Training plus checkpoint validation: 34.9 minutes. Peak MLX allocation: 7,865,167,668 bytes. Packaged model: 2,389,468,280 bytes, below 3 GB decimal.

The complete watchdog run, including package verification and final testing,
took **35.95 minutes** and exited with code zero, without a watchdog stop. Peak
process-tree RSS was 3,006,267,392 bytes; minimum system available memory was
2,230,484,992 bytes. MLX allocation and RSS measure different things.

Verification checked every packaged file hash, the selected and packaged adapter
hashes, exact byte total, three matching decisions after adapter reload, five
schema-valid runtime smoke objects, and the final-test access marker after
selection was frozen. The marker and report record one evaluation of 68 rows.
No final-test model rerun was performed during this verification. The 15 unit
tests passed before launch; actual training and deployed-runtime checks also ran.

The local package is `.local/finetune/package-full-v1`. Original base and probe
packages remain intact. The 632-step final checkpoint scored below checkpoint
512, so the last checkpoint was not automatically selected. No further epoch
was run and no production deployment was performed.

The JSON contract remains type/category/review, with no numeric confidence. All model suggestions still require application review. Acceptance coverage is zero; accepted-error rate is undefined. Per-source and per-category metrics are in the JSON reports.

Limitations: AI labels, synthetic data, sparse classes, small Canadian subset, no real calibration, no future-known-merchant test, no production deployment. Base and probe remain available for rollback.
