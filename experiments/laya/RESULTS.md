# Laya local fine-tuning results

Completed on the frozen 2,077-row training / 279-row validation dataset.
All labels are synthetic and AI-reviewed. No sealed test was opened.

| Validation metric | Original Laya | Fine-tuned Laya | Existing Qwen v2 |
|---|---:|---:|---:|
| Category accuracy | 26.9% | 68.8% | 82.1% |
| Type accuracy | 16.8% | 96.1% | 93.5% |
| Review agreement | 69.5% | 85.7% | 90.0% |
| Exact three-field accuracy | 10.0% | 65.2% | 78.1% |
| Supported-category macro-F1 | 0.202 | 0.632 | 0.806 |
| Invalid final outputs | 0 | 0 | 0 |

Selected epoch: **3** from 4 evaluated epochs.
Selection uses supported-category macro-F1, then exact three-field accuracy, fewer invalid outputs and earlier epoch.
Training/evaluation runtime: 106.2 minutes. Stop: epoch_limit.

Mean warmed single-transaction latency: base 0.193 s; packaged fine-tune 0.181 s.
Fine-tuned package: **1,688,886,175 bytes**, under 3 GB decimal.
Packaged runtime/weights reload: 279 validation rows, 0 prediction changes.

Base and trained Laya use the same three questions, neutral temperature 1, eager fp32 MPS inference and joint schema decoder.
Independent-head invalid combinations: base 197/279; trained 18/279.
These counts are reported before the constraint; zero final invalid objects does not imply correct decisions.

Qwen's saved report is reused on identical inputs/labels; prompts and model runtimes differ. Timing was measured on different runs and is not a controlled speed ratio.
Do not interpret synthetic accuracy, fitted distributions or review=false as real-world calibration. Application suggestions always require review.

Local package: `.local/laya/package`. Original checkpoint, discarded probe boundary, Qwen models and all held-out datasets are preserved.
Per-category/source/currency/type metrics, artifacts and package hashes are in the JSON reports. No production deployment or recurring monitor was created.
