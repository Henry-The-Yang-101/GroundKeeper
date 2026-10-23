# Optional merchant-context pipeline smoke — 2026-10-23

This checks wiring, not representative classification accuracy. Search remains
off by default and every suggestion requires review.

The signed sandboxed Debug app's separate DDGS XPC helper successfully searched
`Staples Waterloo Ontario`, returning two matched sources. Its first attempt
failed DNS resolution in primp's default resolver. Configuring primp 2.0.1 with
the macOS system resolver fixed that failure while retaining its chosen browser
profile and TLS verification. The original standalone 14-query pacing batch
has not been repeated for this packaged configuration; 10.5-second completion-to-
next-search spacing remains an experimental starting point.

Both local production worker paths were compared on one `STAPLES WATERLOO`
input with debit direction and CAD currency. The enriched case used a manually
shortened public office-supplies snippet from the retrieved Staples evidence,
plus its source URL. DDGS did not generate a merchant description. The comparison
performed no searches and did not change weights or tune prompts against the case.

| Model package | Baseline | With merchant evidence |
| --- | --- | --- |
| `qwen-full-v1-step512` | expense / shopping | expense / software |
| `laya-epoch3` | expense / groceries | expense / shopping |

All four outputs had `review=true`. Using shopping as this case's expected
business-purpose category, enrichment helped Laya and worsened Qwen. One case
cannot estimate general accuracy or justify automatic acceptance. Do not treat
the two-call timing observations as a performance benchmark: baseline ran first.

Reproduce with `scripts/benchmark_merchant_context.py` using explicit local
fixtures and a new output path for each provider. Compare held-out cases,
including unseen merchants and ambiguous names, before changing acceptance policy.
Local artifacts are under ignored `.local/merchant-search-ddgs/pipeline-smoke/`.
