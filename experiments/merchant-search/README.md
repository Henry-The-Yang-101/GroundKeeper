# DuckDuckGo merchant-context diagnostic

Research-only retrieval experiment requested on 2026-10-22. It tests whether
DDGS snippets contain enough evidence to describe a public business's type.
It does not score Qwen, alter the classifier contract, or provide calibrated
merchant matching or automatic category acceptance.

## Method

- Seven distinct merchants: the requested Staples, Farah Foods and Foodie
  Frutie, plus Seven Shores, The Bauer Kitchen, Gol's Lanzhou Noodle and Korner
  Kitchen in Waterloo, Ontario.
- Primary queries contain the name and locality, with no added expected type.
  Additional fixtures contain the three requested names alone, fictional
  bank-style descriptors, and an invented negative control. Run records identify
  which cases were actually attempted; fixture inclusion is not test completion.
- DDGS 9.16.0, `backend="duckduckgo"`, `region="ca-en"`, maximum five results,
  one search thread and a 12-second HTTP timeout. The engine registry is restricted
  to DuckDuckGo as well, preventing fallback to another search provider.
- Requests use the installed adapter's POST interface at
  `https://html.duckduckgo.com/html/`. The guard disables redirects and rejects
  other destination hosts. It records statuses, response sizes/hashes and timing;
  it does not visit returned URLs.
- Each isolated query has a 30-second subprocess bound. Shared-client mode uses
  the same DDGS instance across queries; the outer watchdog bounds that run.
  The run stops on a bot challenge or three consecutive unsuccessful queries.
- Public names only. No private transactions, amounts, actual geotags, local
  model calls or cloud classification calls enter the experiment.
- Raw results are retained under ignored `.local/merchant-search-ddgs/`.
  Committed findings contain paraphrases and source links. Concise business
  descriptions in the report are an agent's manual reading of search evidence,
  not an output synthesized by DDGS or a tested automatic extractor.

## Reproduce

From the repository root, using the existing root environment for the watchdog:

```sh
uv venv --python .venv/bin/python .local/merchant-search-ddgs/venv
uv pip install --python .local/merchant-search-ddgs/venv/bin/python -r experiments/merchant-search/requirements.txt
.local/merchant-search-ddgs/venv/bin/python scripts/research_merchant_search.py --validate-only
.venv/bin/python scripts/run_bounded.py --seconds 600 --overall-seconds 1800 --rss-gb 2 --runs-dir .local/merchant-search-ddgs/new-session --label ddg-shared -- .local/merchant-search-ddgs/venv/bin/python scripts/research_merchant_search.py --shared-client --gap-seconds 20 --output .local/merchant-search-ddgs/new-session/results.jsonl
```

Outputs refuse overwrite. Use a new output/session directory for an intentional
new run. Do not repeatedly retry challenges; the runner stops rather than solve
them, rotate proxies, or switch engines. Historical query success establishes
neither permission from DuckDuckGo nor future availability.

## How DDGS works without an LLM

The search engine supplies already-written titles and snippets. DDGS sends HTTP
requests and extracts fields using HTML selectors. It deduplicates result URLs
and applies simple local ranking rules: Wikipedia first, followed by buckets
based on whether any query word occurs in the title, snippet, both or neither.
These are string operations. DDGS does not itself determine that a merchant is
a restaurant, compose an evidence-based summary or verify a purchase's purpose.

Source: [DuckDuckGo adapter](https://github.com/deedy5/ddgs/blob/main/ddgs/engines/duckduckgo.py),
[ranking code](https://github.com/deedy5/ddgs/blob/main/ddgs/similarity.py).

See [RESULTS.md](RESULTS.md) for measured results, retrieval failures and limits.
