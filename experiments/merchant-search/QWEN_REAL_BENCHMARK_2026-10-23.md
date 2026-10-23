# Qwen on real transaction descriptions — 2026-10-23

**DDGS produced a modest increase in frozen reference-label agreement for both Qwen packages.** Original Qwen3.5-4B rose from 39/100 to 44/100 category agreement; the current transaction adapter rose from 54/100 to 58/100. Search context was accepted for 67/100 rows. These are genuine published transaction descriptions, with existing AI-reviewed references and **zero human-confirmed labels**. They do not establish production accuracy or justify automatic acceptance.

## Results

All four configurations classify the same 100 transactions. Enrichment falls back to the original input on rejected queries or missing matches; those rows remain in the denominator.

| Model | Input | Category agreement | Type agreement | Type + category agreement | Median inference | p95 inference |
| --- | --- | --- | --- | --- | --- | --- |
| Original Qwen3.5-4B, no GroundKeeper adapter | Description only | 39/100 | 44/100 | 27/100 | 0.69 s | 0.72 s |
| Original Qwen3.5-4B, no GroundKeeper adapter | Description + DDGS when available | 44/100 | 59/100 | 39/100 | 1.00 s | 1.18 s |
| `qwen-full-v1-step512` | Description only | 54/100 | 83/100 | 50/100 | 0.70 s | 0.72 s |
| `qwen-full-v1-step512` | Description + DDGS when available | 58/100 | 86/100 | 55/100 | 1.02 s | 1.19 s |

Inference timing excludes search, package preparation and one warm-up prediction on the first real row. All 400 outputs passed the production schema validation and required review. Full type/category/review agreement is preserved in the JSON, but is not the primary metric: production forces review while many frozen references permit acceptance.

| Paired category outcome | Original Qwen | Current adapter |
| --- | --- | --- |
| Both agree with reference | 33 | 49 |
| Only description-only agrees | 6 | 5 |
| Only enriched agrees | 11 | 9 |
| Neither agrees | 50 | 37 |
| Category changed | 24 | 15 |
| Net agreement change | +5 percentage points | +4 percentage points |

All changes occurred on rows receiving context. The 33 rows without accepted context produced identical complete decisions in both modes.

| Category agreement subset | Original, description only → enriched | Current adapter, description only → enriched |
| --- | --- | --- |
| All transactions, n=100 | 39 → 44 | 54 → 58 |
| Distinct description strings, n=96 | 39 → 42 | 54 → 56 |
| Originally high-certainty references, n=63 | 27 → 29 | 41 → 42 |
| Rows with accepted context, n=67 | 27 → 32 | 40 → 44 |

Repeated merchants contribute to the transaction-weighted gain: `GRAINGER` occurs three times and changes from a disagreement to agreement in each model. The distinct-description result removes exact duplicate strings, but is not a merchant-family holdout.

## Data and scoring limits

The source is the public [Delaware Credit Card Expenditures dataset](https://data.delaware.gov/resource/nurt-5rqw.json), with [official metadata](https://data.delaware.gov/api/views/nurt-5rqw.json). The project already froze this 100-row diagnostic on 2026-10-17, before its original inference runs. It was sampled uniformly without replacement from 2,251,316 published rows using seed `20261017`, with stable source IDs. We reused every row and its existing reference; no resampling, new annotation or training occurred.

The inputs contain the original merchant/transaction-description string, `direction="unknown"` and `currency=null`. No amounts, MCCs, dates, agency names, source labels, receipt evidence or Wallet category hints enter classification. No merchant locality was available, so locality remains empty; the production search region remains `ca-en`. The queried name comes from the actual Swift description-fallback sanitizer, not manually rewritten merchant names.

Examples of unmodified input strings include `MCDONALD'S F4566`, `GODADDY#4095988064`, `UPS*BILLING CENTER` and `GAN*NEWSPAPER SUB1052`. These are real institutional card records from the US, not synthetic descriptions, private personal-bank data or a Canadian personal-spending validation set. This historical diagnostic is not a fresh sealed final test. Existing sealed test sets were not accessed or changed.

References were previously written by one AI reviewer: 63 high, 32 moderate and 5 low certainty; zero human confirmations. They are imbalanced across 12 categories, with 33 shopping and 22 uncategorized examples, and do not cover the complete transaction-type/category policy. The reference decisions were based on descriptions alone and remain unchanged after retrieval. Additional evidence can legitimately move an ambiguous description to a specific category, so a disagreement with these references is not by itself proof of an incorrect classification.

## Retrieval and latency

- 83 distinct uncached searches, one reused client, serialized requests.
- 10 row-level cache hits; 7 descriptions rejected by the production query sanitizer before networking.
- 67 rows received accepted context; 26 were no-match fallbacks and 7 were rejected-query fallbacks.
- No CAPTCHA, provider block or unavailable outcome in this batch. All 83 scheduled uncached searches were attempted.
- Collection wall time: 908.83 seconds (15 minutes 8.83 seconds).
- Median uncached search-call wall time including the pacing wait: 11.064 seconds. The first call had no preceding cooldown and took 0.968 seconds.

This uses production `groundkeeper.merchant_search.MerchantSearch`, DDGS 9.16.0, DuckDuckGo HTML only, `region="ca-en"`, `max_results=5`, and a 10.5-second gap after search completion. The guard permits only the DuckDuckGo HTML endpoint and prevents redirects and other-engine fallback. Returned URLs are evidence only; the runner does not visit them. Context contains at most two bounded titles/snippets/URLs, with the same untrusted-evidence prompt instructions as the app; no generated merchant summary is substituted.

Both enriched models consume exactly the same saved evidence. No manually shortened snippets or hand-selected successful subset were used. A blocked search would stop the batch and leave subsequent rows as fallback classifications; no retries, challenge solving or alternate provider were needed. One passing 83-query batch on one connection is not a guaranteed provider rate limit.

The roughly 11-second lookup pacing dominates cold batches. Adding context increased median model time by about 0.3 seconds. Cached evidence avoids a new network lookup and its wait. These are separately measured collection and inference phases, not a measurement of complete app/XPC queue latency; they should not simply be added to predict every app transaction's latency. Baseline inference overlapped the lightweight collector; model runs themselves were sequential, not randomized or conducted on an otherwise idle machine.

## Real examples and unresolved ambiguity

| Published description | Frozen reference category | Original Qwen, baseline → enriched | Current adapter, baseline → enriched |
| --- | --- | --- | --- |
| `GODADDY#4095988064` | software | null → software | software → software |
| `BELAIR ROAD SUPPLY CO` | shopping | other → shopping | uncategorized → shopping |
| `NAME.COM INC` | software | uncategorized → software | uncategorized → software |
| `GAN*NEWSPAPER SUB1052` | entertainment | uncategorized → entertainment | uncategorized → entertainment |
| `UPS*BILLING CENTER` | other | uncategorized → financial | uncategorized → financial |
| `HERTRICH CAPITOL` | uncategorized, low certainty | uncategorized → vehicle | uncategorized → vehicle |

`null` is a schema-valid category on certain non-expense transaction types; the full decisions are in the aggregate JSON's changed-row records. UPS illustrates a remaining semantic error relative to the reference: adding billing-page evidence still did not produce the reference's `other` label for shipping/postal spending. HERTRICH illustrates a description-only reference becoming more specific with new evidence; that move requires adjudication rather than automatically calling it right or wrong.

Merchant identity was not independently labeled. For example, the name-only query `G AND E INC` accepted snippets about G.E. Logistics and a separate company profile. This demonstrates ambiguity when locality is absent: a lexical match is not verified merchant identity. The reported 67% context coverage is acceptance by the current matcher, not measured merchant precision. Keep this optional, retain review, and obtain independently reviewed merchant identities/categories before treating the modest agreement gains as accuracy evidence.

## Model and run provenance

- Original model: Qwen3.5-4B, existing text-only MLX 4-bit extraction of `mlx-community/Qwen3.5-4B-MLX-4bit`, upstream revision `32f3e8ecf65426fc3306969496342d504bfa13f3`. No GroundKeeper adapter is present or loaded in the original-model package.
- Original text weight SHA-256: `d58b87def677c7b3235e21cdca85289a162a5ba8949687b9573592e3c74cd477`. The new package's weights were verified byte-for-byte against `.local/finetune/models/qwen35-text/model.safetensors` before inference. Both configurations use identical base weights.
- Current adapter: `qwen-full-v1-step512`; adapter weight SHA-256 `efa206566bb1a1b9e5e6f4695cdf6b1a0cee34b11953753efa7aabe6a7bd2`. No Delaware continuation adapter was substituted.
- Both packages use policy `groundkeeper-18-v1`, prompt `v1`, production constrained decoding, temperature zero and thinking disabled. The original model is evaluated through this classifier pipeline, not a separately optimized general-purpose prompt.
- Hardware/runtime: Apple M4 Pro, 24 GiB unified memory, macOS 27.0.1, Python 3.12.9, MLX 0.32.3, mlx-lm 0.32.0, transformers 5.19.0, tokenizers 0.23.2.
- Search runtime: DDGS 9.16.0, primp 2.0.1, lxml 6.1.3, click 8.5.0. Production implementation commit: `30d655f`; inference harness milestone: `f660db5`.
- Frozen sample SHA-256: `cba58b704ff848ac52bb8bd12071b141ecd1c3e0efa9521660b4e4ad91ebb4da`.
- Frozen reference SHA-256: `f69cd5e82277b2cab663216e9252779c5f2ae220ed9892bd8301c13477edffb8`.

The aggregate [machine-readable result](qwen-real-benchmark-2026-10-23.json) records prediction/evidence hashes, model identities, timing, subset metrics, paired results and every changed complete decision, including those rows' public descriptions. Full input/evidence/prediction files remain under ignored local directories; no search HTML, challenge tokens, generated runtime or model weights are committed.

## Reproduction and validation

Use the existing immutable source directory `.local/real-eval/delaware-100-20261017-v1`. Create a fresh run directory and construct a verified original-model package by copying only the installed Qwen package's `model/` files, omitting `adapters/` and `EXPERIMENTAL.txt`, removing `adapter_directory` and their file-manifest entries, and assigning a distinct model ID. Preserve the prompt and policy versions. Verify the text weight hash against the original source above; `Worker.prepare_model` also checks every package file against its manifest. This is a separate package; the installed package is not modified.

The recorded run directory is `.local/real-eval/ddgs-qwen-base-20261023-v1`, containing `plan.json`, `environment.json`, `queries.jsonl`, `base-package/`, `evidence.jsonl`, `base-baseline.jsonl`, `base-enriched.jsonl`, `finetuned-baseline.jsonl`, `finetuned-enriched.jsonl`, `summary.json` and watchdog reports/logs. Plan/environment metadata are frozen before scoring. Use fresh paths for any intentional new experiment; commands refuse to replace outputs.

```sh
swift build --package-path apps/macos/GroundKeeperCore --scratch-path .local/macos/CoreBuild --product MerchantQueryPilot
.local/macos/CoreBuild/debug/MerchantQueryPilot .local/real-eval/delaware-100-20261017-v1/sample.jsonl > <new-run>/queries.jsonl
.local/merchant-search-ddgs/venv/bin/python -m scripts.benchmark_real_merchant_search collect --source .local/real-eval/delaware-100-20261017-v1 --queries <new-run>/queries.jsonl --output <new-run>/evidence.jsonl
.venv/bin/python -m scripts.benchmark_real_merchant_search predict --source .local/real-eval/delaware-100-20261017-v1 --package <new-run>/base-package --output <new-run>/base-baseline.jsonl
.venv/bin/python -m scripts.benchmark_real_merchant_search predict --source .local/real-eval/delaware-100-20261017-v1 --package <new-run>/base-package --evidence <new-run>/evidence.jsonl --output <new-run>/base-enriched.jsonl
.venv/bin/python -m scripts.benchmark_real_merchant_search predict --source .local/real-eval/delaware-100-20261017-v1 --package .local/macos/models/qwen --output <new-run>/finetuned-baseline.jsonl
.venv/bin/python -m scripts.benchmark_real_merchant_search predict --source .local/real-eval/delaware-100-20261017-v1 --package .local/macos/models/qwen --evidence <new-run>/evidence.jsonl --output <new-run>/finetuned-enriched.jsonl
.venv/bin/python -m scripts.benchmark_real_merchant_search score --source .local/real-eval/delaware-100-20261017-v1 --run <new-run> --output <new-run>/summary.json
```

The recorded commands additionally used `scripts/run_bounded.py`: collection limited to 1,800 seconds/2 GB process-tree RSS, each prediction run to 900 seconds/12 GB RSS, with a 3,600-second overall session limit and system-memory monitoring. Every process completed normally. MLX retains the production 10 GiB allocator limit and 128 MiB cache limit; watchdog RSS is not a complete measure of Metal/unified-memory use.

Validation: native query pilot compiled; 171 Python tests and 45 Swift tests passed. Scoring checked frozen sample/reference hashes, all 100 aligned IDs per configuration, exact original-input hashes with only optional context added, common prompt versions, shared evidence hashes and the absence of a base-model adapter. No model, prompt, cleaner or matcher was tuned using these results.
