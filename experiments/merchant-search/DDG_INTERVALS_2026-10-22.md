# DuckDuckGo request-spacing diagnostic — 2026-10-22–23

**10.5 seconds after each search returned was the shortest tested pause that
completed the full fourteen-query fixture without a CAPTCHA.** A 10.0-second
full-batch attempt passed eight queries but received a challenge on query nine,
`Farah Foods` (name only), despite passing the initial two-query screen.

The 10.5-second and 20.0-second complete batches each returned nonempty results
for all thirteen business queries, and an empty result for the invented
negative control. The 10.5-second batch took 145.924 seconds including pauses;
actual request starts were 11.013–11.638 seconds apart (median 11.081 seconds).

These are observations on this connection over 2026-10-22–23, not a guaranteed
minimum or provider-published rate limit. Fourteen runs/controls made 58 HTTP
requests in total. Each successful full-batch interval was tested once; the
two-query screens and single-query control have narrower scope.

## Method

- Use the existing fourteen-case fixture in its original order, beginning with
  `Staples Waterloo Ontario` and then `Farah Foods Waterloo Ontario`. Do not
  remove the difficult query to obtain a passing batch.
- Restrict DDGS 9.16.0 to its stock DuckDuckGo adapter. The engine registry and
  exact-host request guard prevent fallback. Each recorded request is a POST to
  `https://html.duckduckgo.com/html/`; result URLs are not visited.
- Reuse one DDGS engine/client within each batch. Other than pacing, retain the
  existing settings: `ca-en`, five results, one thread, twelve-second timeout.
  Each batch has a fresh client; DDGS's stock random browser/OS profile is an
  uncontrolled variable across batches. No custom profile, proxy, engine switch
  or CAPTCHA solving is introduced.
- Stop a batch immediately at its first challenge. Allow at least 120 seconds
  after a challenge before the next batch/control request. This is an
  experimental recovery pause, not a verified time at which protection resets.
  Subsequent screens wait at least twenty seconds after a successful batch.
  Full confirmations at candidate gaps also begin after at least 120 seconds
  idle, even when the preceding screen passed.
- The configured pause begins after the search call finishes. Record monotonic
  HTTP start/end times to distinguish this from start-to-start spacing.
- Use public merchant names only. No private transactions, real geotags, model
  calls, classifier changes or training runs are involved.

## Observations

| Configured pause after response | Measured response-to-next-request gap | Measured request-start interval | Result |
| --- | --- | --- | --- |
| 0.5 s | 0.505 s | 1.250 s | Staples HTTP 200; Farah HTTP 202 with challenge markup. |
| 1.0 s | 1.013 s | 1.754 s | Same; stopped after query two. |
| 1.5 s | 1.507 s | 2.326 s | Same; stopped after query two. |
| 2.0 s | 2.009 s | 2.888 s | Same; stopped after query two. |
| 5.0 s | 5.015 s | 6.138 s | Same; stopped after query two. |
| 10.0 s | 10.011–10.020 s | 10.532–10.814 s | Eight successes; HTTP 202 challenge on query nine, `Farah Foods`. |
| 10.5 s | 10.507–10.519 s | 11.013–11.638 s | All fourteen HTTP 200; thirteen business results and one empty negative control. |
| 20.0 s | 20.011–20.029 s | 20.625–20.902 s | All fourteen HTTP 200; thirteen business results and one empty negative control. |

Only two of the fourteen planned queries were reached in each failed batch
below 10.0 seconds; nine were reached at 10.0 seconds.
HTTP 202 alone is not used to infer CAPTCHA: the response also contained the
DuckDuckGo challenge markers checked by the runner.

A separate one-query control searched **Farah first**, after 120.293 seconds of
idle time following the 1.0-second batch. It returned HTTP 200 and five nonempty
results with useful Waterloo grocery/convenience-store context. Its configured
twenty-second gap was never exercised because there was only one request. This
shows the exact query can be retrieved; it does not isolate why the paired
sequence is challenged. The 1.5-second batch began 33.114 seconds after that
successful control, with no intervening challenge.

After the complete twenty-second pass, binary refinement on the half-second
grid used only the first two queries as a screen. These are **two-query
observations**, not fourteen-case passes:

| Configured gap | Actual response-to-next-request gap | Two-query screen |
| --- | --- | --- |
| 12.5 s | 12.509 s | Both HTTP 200 with results. |
| 8.5 s | 8.520 s | Staples HTTP 200; Farah HTTP 202 challenge. |
| 10.5 s | 10.509 s | Both HTTP 200 with results. |
| 9.5 s | 9.518 s | Staples HTTP 200; Farah HTTP 202 challenge. |
| 10.0 s | 10.014 s | Both HTTP 200 with results. |

The order above is execution order, not sorted by interval. Refinement uses an
approximately monotonic pacing hypothesis to choose the next screen; it does
not test every skipped grid point or prove that hypothesis.

Full confirmation then attempted all fourteen cases at 10.0 seconds, stopped
on query nine, and, after 120.297 seconds idle, retried the complete fixture in
a new batch at 10.5 seconds. That batch finished without a challenge. The
9.5-second failure, 10.0-second partial pass and 10.5-second complete pass must
not be reduced to a passing two-query threshold of ten seconds.

## Interpretation

An observed boundary in this query pair does not identify a deterministic
provider rate limit. Query order, session/profile variation, cumulative traffic
and provider-side state remain possible factors. These small sequential trials
use one complete batch per passing interval and cannot isolate those effects.

The [earlier twenty-second trial](RESULTS.md) attempted twelve remaining cases,
excluding the original Staples and Farah name-plus-locality queries. It must
not be described as a complete fourteen-case batch or proof that twenty seconds
is safe for this sequence. The new twenty-second run above includes both and
passes the complete fixture.

For a prototype, keep lookups optional, cache reusable merchant context locally,
serialize uncached queries and stop/back off when challenged. A fixed pause
cannot currently be treated as a dependable service guarantee. **10.5 seconds
is the smallest complete-batch success observed here**, with the adjacent
10.0-second candidate failing the same fixture. Replication across sessions and
times is needed to estimate reliability; skipped lower grid points and other
query orders were not tested exhaustively.

## Evidence

- [Machine-readable observations](ddg-intervals.json) contain query outcomes,
  timings, artifact hashes and idle periods, without raw snippets or challenge
  tokens.
- Raw JSONL, diagnostic HTML and watchdog logs remain in ignored
  `.local/merchant-search-ddgs/interval-probe/`.
- [Runner](../../scripts/research_merchant_search.py),
  [fixtures](cases.json), [dependency pins](requirements.txt),
  [reproduction and method](README.md).

The harness now accepts finite gaps of at least 0.5 seconds and records monotonic
transport timing. Offline checks validate pacing inputs, Python syntax, exact
provider hosts and request timing. These checks concern the research harness;
no application or classifier behavior changed.
