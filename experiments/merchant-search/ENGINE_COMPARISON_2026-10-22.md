# DDGS engine comparison — 2026-10-22

**DuckDuckGo remained the most useful tested source for merchant context.**
Brave and Google encountered access controls immediately. Bing returned HTTP
200 pages, but its pinned adapter had broken selectors and the recovered result
sets were usually unrelated to the requested merchant.

These are observations from this computer/network at low volume, not established
rate limits, population estimates, provider permissions or a classifier score.

## Protocol

Used the same fourteen [cases](cases.json), DDGS 9.16.0 and dependency pins as
the original [DuckDuckGo trial](RESULTS.md): thirteen business queries across
seven merchants, plus an invented negative control. Each provider had a separate
process, one reused client, one search thread, a maximum of five results and a
twenty-second gap. The three initial provider runs started concurrently; calls
within each provider remained sequential. There were no source-page fetches,
API keys or model calls. All names/descriptors were public or fictional.

The harness registers only the requested adapter, records exact request hosts
and response metadata, and stops on a challenge or three consecutive unsuccessful
queries. It permits only audited ordinary redirects within that provider's
exact host. Challenge redirects are detected before following them. There was
no proxy rotation, browser-profile modification, CAPTCHA solving or retry loop.
The underlying DDGS HTTP client already uses its own default browser
impersonation; that default was preserved.

## Observed results

| Run | Queries actually attempted | Response/access result | Usable merchant evidence |
| --- | ---: | --- | --- |
| DuckDuckGo, previous trial | 14 | One bot challenge; later shared-client pass completed. | Twelve of thirteen business queries supported business-type context; all seven merchants represented. Negative control had an empty row. |
| Brave, stock | 1 | HTTP 429 on Staples; response HTML said the request was suspicious and a CAPTCHA was scheduled. | None. Run stopped; thirteen cases unattempted. |
| Google, stock | 1 | HTTP 403 on DDGS's older `/wml/search` route. | None. This response alone does not establish a CAPTCHA or rate-limit cause. |
| Google, standard-route diagnostic | 1 | Changed only the endpoint to `/search`; HTTP 302 pointed to `/sorry/index`, a challenge route. Redirect was not followed. | None. Only the first Staples query was used for this endpoint diagnostic. |
| Bing, stock selector diagnostic | 3 | All HTTP 200. Upstream disables this adapter; it was explicitly registered without enabling any fallback. Its selectors failed to obtain titles/URLs. | Zero nonempty complete results; stopped after three unsuccessful queries. |
| Bing, corrected selectors | 14 | All HTTP 200; no explicit challenge detected. | Four of thirteen business queries supported merchant context, covering Staples and Foodie Fruitie. The other nine business queries and the negative control returned unrelated evidence. |

The Bing selector diagnostic completed in 266.82 seconds including delays.
It obtained results for the three Staples variants and the name-only Foodie
Frutie query. Foodie's result set included menu/delivery listings and explicit
restaurant cuisine evidence. The business-name spelling was handled, but the
same merchant with locality or fictional descriptor text returned unrelated
results. Fast HTTP responses therefore did not imply successful resolution.

Examples from that Bing diagnostic:

- `Seven Shores Waterloo Ontario` returned film/number results about Seven.
- `The Bauer Kitchen Waterloo Ontario` returned hockey-equipment results.
- `Gol's Lanzhou Noodle Waterloo Ontario` returned airline results.
- Name-only `Farah Foods` returned hotel results.
- The invented name returned five unrelated shopping/sales results.

The captured page titles and recorded query parameters contained the requested
queries. No conclusion about why Bing returned these result sets is justified:
request/profile/locale behavior, ranking or undocumented mitigation could be
involved. This is not evidence that Bing intentionally poisons results or that
its ordinary browser search has the same quality.

## Separating parsing from blocking

The installed Bing adapter expects `<h2><a>...</a></h2>`, while the captured pages
used `<a><h2>...</h2></a>`. The explicit `bing-selectors` variant accepts both
structures and extracts heading text regardless of anchor placement. It leaves
the request endpoint, parameters and client behavior unchanged. Saved baseline
HTML was first parsed offline; a separate live pass then used all fourteen
queries. This is a local research adaptation, not a shipped upstream repair.

Google's `/search` diagnostic was one additional request to determine whether
the stock endpoint's 403 was the only access problem. The installed Google
adapter's headers/parameters were retained. No challenge page was accessed and
no claim is made that its old parser could handle a modern search page.

## Practical implications for bot protection

The robust ways to reduce request volume are merchant-level caching,
deduplicating queued names, one request at a time, and backing off on rejection.
A real browser can execute JavaScript and preserve ordinary session state, but
it adds a browser/runtime dependency and may still require a person to complete
a CAPTCHA. Browser impersonation already present in DDGS did not prevent the
Brave or Google failures in this trial.

Proxy/IP rotation and outsourced CAPTCHA solving are additional technical
approaches, but they introduce paid external dependencies, privacy questions and
ongoing maintenance. They do not establish permission from a provider and were
not tested. Google explicitly notes that shared/VPN traffic can itself trigger
blocks. A universally reliable unattended keyless bypass is not established by
these experiments.

For GroundKeeper, keep enrichment optional, cache resolved public merchant
context locally and require identity/locality evidence before using snippets.
On failure, preserve the original classification/review path. If unattended
reliability becomes essential, an authorized API or downloaded merchant data
is a more predictable dependency than adapting search scrapers indefinitely.

Sources: [DDGS client](https://github.com/deedy5/ddgs/blob/main/ddgs/http_client.py),
[Bing adapter](https://github.com/deedy5/ddgs/blob/main/ddgs/engines/bing.py),
[Google unusual-traffic guidance](https://support.google.com/websearch/answer/86640?hl=en),
[Playwright session-state documentation](https://playwright.dev/python/docs/auth).

## Artifacts and checks

[Machine-readable comparison](engine-comparison.json) records attempted queries,
HTTP status counts, manual relevance judgments, timing and raw-file hashes.
Ignored raw JSONL, diagnostic HTML and watchdog logs are retained separately
under `.local/merchant-search-ddgs/comparison/<run>/`. HTML/redirect URLs may
contain ephemeral challenge tokens or network identifiers; they are not copied
into committed summaries.

Offline checks verified selected-engine isolation, corrected Bing extraction,
cross-provider redirect rejection and stopping before a Google challenge
redirect. The three baseline runs, the fourteen-query Bing diagnostic and the
one-query Google-route diagnostic all finished inside their watchdog bounds.
Production application, classifier and training code were not changed.
