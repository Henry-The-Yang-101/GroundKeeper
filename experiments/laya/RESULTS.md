# Original Laya benchmark

Measured on 2026-10-09 using the frozen 279-row Qwen v2 validation set. All labels
are synthetic and AI-reviewed. No final-test data was opened.

| Metric | Original English Laya | Existing Qwen v2 checkpoint 2080 |
|---|---:|---:|
| Category accuracy | 26.9% | 82.1% |
| Supported-category macro-F1 | 0.202 | 0.806 |
| Type accuracy | 16.8% | 93.5% |
| Review agreement | 69.5% | 90.0% |
| Exact type/category/review accuracy | 10.0% | 78.1% |
| Invalid final outputs | 0 | 0 |
| Mean single-transaction latency | 0.193 s | 1.179 s |

Both columns use identical transaction inputs and labels, with each model's
native prompt and schema-constrained runtime. Qwen measurements are reused from
its saved validation report, not a new model run. Their inference dates differ,
so latency is descriptive and is not a controlled hardware speed ratio.

Laya's independent answers formed invalid type/category/review combinations on
197/279 rows; joint schema decoding changed those 197 decisions. Before that
constraint, type/category/review field accuracies were 14.0%/25.1%/69.5%.
Zero invalid outputs is a decoding guarantee, not model correctness.

Original checkpoint revision: `55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851`.
Laya 0.4.1 / PyTorch 2.14.0 / Transformers 5.19.0, eager fp32 MPS, temperature 1.
Warmed single-transaction inference asks all three questions together. The mean
includes field decoding and explicit MPS synchronization; model loading is
excluded. Median latency was 0.184 s. The entire bounded job took 62.9 seconds,
peaked at 2.16 GB process RSS, and exited successfully.

Fine-tuning compatibility measurements and results will be added after the run.
No real-data calibration or automatic acceptance is established.
