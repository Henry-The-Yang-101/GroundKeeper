# DuckDuckGo merchant-context trial — 2026-10-22

**The snippets supported a useful business-type description for all seven
merchants in at least one tested query.** Twelve of thirteen business queries
returned nonempty results; one received a bot challenge. This is a small
retrieval diagnostic with agent-reviewed descriptions, not measured category
accuracy or representative reliability.

No LLM was called. The descriptions below are the reviewing agent's concise
reading of returned titles/snippets. DDGS itself returned the search evidence,
not these descriptions. Source pages were not fetched by the experiment.

## Business evidence

| Merchant | Concise supported context | Evidence and limitation |
| --- | --- | --- |
| Staples | Office-supply/electronics retailer offering printing services. | The official [Waterloo store result](https://stores.staples.ca/on/waterloo/office-supplies-ca-120.html) describes its product lines. This cannot distinguish stationery, electronics or other purchased items. |
| Farah Foods | Grocery/convenience retailer with mixed product lines. | The fictional descriptor query returned a [Waterloo grocery-store listing](https://canada.chamberofcommerce.com/business-directory/ontario/waterloo/grocery-store/651196-farah-foods), [convenience-retail description](https://farah-foods-1.wheree.com/) and [local Facebook snippet](https://www.facebook.com/farahs170/). Name-only results mix Waterloo, Hamilton, Brant and Kitchener; exact branch remains unresolved. |
| Foodie Frutie | Restaurant with sushi/Asian-food menu evidence. | The search returned the spelling **Foodie Fruitie**, with [sushi-menu](https://foodie-fruitie.wheree.com/menu) and [restaurant-listing](https://www.tripadvisor.ca/Restaurant_Review-g181736-d12133229-Reviews-Foodie_Fruitie-Waterloo_Region_of_Waterloo_Ontario.html) evidence. The first Yelp snippet was mostly generic nearby-food categories, so the first snippet alone is insufficient. |
| Seven Shores | Community cafe in Uptown Waterloo. | The [official-site snippet](http://www.sevenshores.ca/) explicitly identifies both type and locality. |
| The Bauer Kitchen | Bistro/restaurant in Waterloo. | An [OpenTable result](https://www.opentable.ca/the-bauer-kitchen) identifies a bistro; the official [menu result](https://www.thebauerkitchen.ca/eats) adds food-service evidence. The first official home-page snippet was mostly address/hours. |
| Gol's Lanzhou Noodle | Noodle restaurant with freshly pulled beef-noodle soup. | The [official Waterloo location](https://lanzhou.ca/waterloo/) supports locality, while a [Yelp snippet](https://www.yelp.ca/biz/gols-lanzhou-noodle-waterloo-2) supplies the specialty. |
| Korner Kitchen | Breakfast/lunch diner. | Its [official-site snippet](https://kornerkitchen.ca/) gives the business type; a [Waterloo restaurant result](https://www.tripadvisor.ca/Restaurant_Review-g181736-d8066171-Reviews-Korner_Kitchen-Waterloo_Region_of_Waterloo_Ontario.html) supports locality. |

These are business-type descriptions, not independently verified current menus,
opening hours, exact purchase identities, item-level categories or ground-truth
labels. In particular, Farah Foods and Staples sell mixed product lines.

## Measured execution

- Environment: Python 3.12.9, DDGS 9.16.0, primp 2.0.1, lxml 6.1.3, click 8.5.0.
- All fourteen recorded HTTP requests went to the DuckDuckGo HTML search
  endpoint using POST. No Google, Brave or other search fallback was available.
  Returned merchant URLs were stored but not opened.
- The first run used a fresh DDGS client per query, with a four-second gap.
  Staples succeeded; `Farah Foods Waterloo Ontario` returned HTTP 202 with
  bot-challenge markup. The run stopped immediately rather than retrying it.
- After a pause of roughly 112 seconds, a second run reused one client and
  spaced queries twenty seconds apart. All eleven remaining business queries
  returned nonempty results, as did the negative-control HTTP request. This
  changes both session reuse and pacing; it does not isolate the cause of the
  improvement or establish an allowable request rate.
- Across successful business queries, measured call time was **0.614–0.960 s**,
  with a **0.796 s median**, excluding intentional gaps and the cooldown. The
  shared-client job took 229.42 seconds including gaps and stayed below 51 MB
  peak process-tree RSS in the watchdog sample.
- Primary name-plus-locality queries: six successes, one challenge. All three
  additional name-only queries and all three fictional bank-style queries
  returned nonempty results. Query variants are repeated merchants, not
  independent samples or a robust fuzzy-matching benchmark.

The negative control, `"Zorblax Quenibble 7F4C" Waterloo Ontario`, did **not**
produce business evidence. DDGS returned one dictionary with empty `title`,
`href` and `body` fields. The original raw capture therefore says `results`,
but its nonempty-result count is zero. The saved runner now marks an all-blank
output as `empty`, while preserving the raw adapter output. This local validation
change was checked offline and did not trigger another live request.

## What this establishes

DuckDuckGo search snippets can supply compact context for these Waterloo
businesses without visiting a source page or asking a cloud LLM. The search
engine also handled the Foodie Frutie/Foodie Fruitie spelling variation and a
fictional Staples branch suffix. That is useful evidence for an enrichment
prototype, not a calibrated matcher.

An enrichment layer still needs to reject empty rows, check name and locality,
look beyond a weak first snippet, prefer more authoritative sources, preserve
evidence and allow no-match. Result rank is not merchant confidence: DDGS's
ranker can match a common word such as Waterloo without resolving the business.

The next evaluation should test an automatic evidence extractor separately from
retrieval, followed by the existing classifier with a versioned compact-context
input. It must compare correct-to-incorrect regressions, abstention and identity
precision on reviewed real descriptions before any automatic acceptance. This
trial neither changed nor evaluated a deployed classification model.

## Artifacts and validation

- [Machine-readable summary](summary.json): query-level outcomes, concise manual
  descriptions, evidence ranks/URLs, timings and raw-artifact hashes.
- [Cases](cases.json), [dependency pins](requirements.txt),
  [runner](../../scripts/research_merchant_search.py), and [method/reproduction](README.md).
- Local-only raw captures: `.local/merchant-search-ddgs/stock.jsonl` and
  `.local/merchant-search-ddgs/shared.jsonl`; watchdog reports/logs under `runs/`.
- Offline checks confirmed case completeness/unique IDs, the fourteen recorded
  request hosts/methods, other-provider rejection before transport, disabled
  redirects, fixture extraction and empty-output rejection. No production
  classifier, training or application test was required for this isolated probe.

The evidence concerns technical retrieval behavior. It does not establish
permission from DuckDuckGo to deploy scraping or guarantee future availability.
