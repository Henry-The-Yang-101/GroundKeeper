# Delaware category-label audit with web evidence — 2026-10-23

**The sample shows substantial under-categorization, while most existing specific categories are supported. It does not support discarding every Delaware label or deleting the fine-tuned models.** Search recovered useful category suggestions for 37 of 89 sampled Uncategorized rows (33 strong matches, four provisional). Of 111 rows with a specific category, 104 were supported, one was clearly miscategorized, four were more specific than the evidence/policy supports, and two could not be settled.

This is a single-reviewer, web-assisted **AI audit with zero human confirmations**, not purchased-item ground truth or a production model accuracy measurement. Original labels, splits, training exports, models and application settings were not changed. No inference or training was run.

## Results

| Audit outcome | Rows | Share of 200 |
|---|---:|---:|
| Existing specific category supported | 104 | 52.0% |
| Existing Uncategorized remains defensible after identifying multiple possible services | 18 | 9.0% |
| Uncategorized has a recoverable category suggestion after search | 37 | 18.5% |
| Specific category clearly wrong | 1 | 0.5% |
| Specific category exceeds the available evidence | 4 | 2.0% |
| Merchant identity or policy boundary remains unresolved | 36 | 18.0% |
| Total | 200 | 100.0% |

**122/200 (61%) are supported as written; 42/200 (21%) are flagged for revision or review; 36/200 (18%) remain unresolved.** If restricted to the 164 adjudicable rows, support as written is 122/164 = 74.4%. That conditional figure excludes difficult unresolved rows and includes four provisional suggestions; it is not an unbiased estimate of true category accuracy.

It would be misleading to call the other 39% categorically wrong. Thirty-seven suggestions benefit from evidence the original labelers did not receive, and 36 rows still cannot be settled. Even a verified merchant default does not prove the actual purchased item.

Among the 89 original Uncategorized rows: 37 (41.6%) have recoverable suggestions, 18 (20.2%) remain defensible abstentions, and 34 (38.2%) are unresolved. The four provisional recoveries are AA WIFI, FRONTIER AI YI6I2A, LOEWS MADISON HOTEL FB and PAYPAL *ASBOG. They require confirmation of the abbreviation, service or payment purpose before being treated as corrected references.

Among the 111 original specific categories: 104 (93.7%) were supported, five (4.5%) were wrong or unsupported in specificity, and two (1.8%) remain unresolved. These are observed sample counts, not human-gold precision estimates.

## Sample and method

- Population: all **7,254 retained** Delaware descriptions across train, validation and test. The 746 quarantined rows were excluded because they were not accepted training/evaluation labels. This audit does not estimate quality across the full original 8,000 including quarantine.
- Sampling: ID-sort the retained population, then `random.Random(20261023).sample(rows, 200)`, then ID-sort the sample for review. No difficult examples or known mistakes were inserted into the random sample.
- Composition: **160 training, 20 validation and 20 test rows**, spanning 194 existing merchant-family identifiers. The unit is one distinct labeled merchant description, not a frequency-weighted transaction or merchant-family sample.
- Every sampled description received its own web query. The saved evidence contains **268 searches: 200 initial searches and 68 follow-up searches**. Search retrieval happened before the original labels/rationales were displayed for comparison. Final adjudication was performed by one Codex reviewer and is not an independent human or second-reviewer assessment.
- Evidence is primarily search-result excerpts with source URLs; eight key pages were additionally opened. This was a manual web audit, not a measurement of production DuckDuckGo retrieval or its matcher. Some queries used likely business-type expansions; a retrieved namesake was not accepted automatically.
- Use the existing [category policy](../docs/transaction-categories.md), [labeling policy](../experiments/finetune/LABELING_POLICY.md) and [v2 clarifications](../experiments/finetune/v2/POLICY_ADDITIONS.md). Explicit purchase/service wording takes priority. Mixed brands, generic acronyms and missing locality can still require abstention.
- Merchant websites, venue operators and relevant official organizations were preferred. Historical coverage was retained for closed venues. Other purchasers' spending descriptions, source MCCs, agency context and amounts were not used to infer the sampled purchase's category.
- Some supported categories rely on explicit wording such as TAXI FARE, SOFTWARE FEE or CHINESE RESTAURANT. Those are marked `purpose_only`: the purpose is supported even though the precise merchant identity was not verified online. The audit does not claim 200 verified merchant identities.

The frozen plan records input hashes. Verification confirmed all three original split files and the frozen sample still match their starting hashes. **The 20 sampled test rows are now semantically audit-exposed.** Keep them out of retraining and do not present them as an untouched final test after acting on these findings.

## Examples and boundaries

| Description | Original category | Audit finding | Evidence |
|---|---|---|---|
| WICKED LOBSTA | Uncategorized | Dining suggestion | [Marketplace operator identifies a seafood restaurant](https://faneuilhallmarketplace.com/go/wicked-lobsta) |
| SP * CHILD1ST PUBLICAT | Uncategorized | Education suggestion | [Reading instruction materials](https://child1st.com/products/easy-for-me-teaching-kit-1) |
| SP DHARMA TRADING CO | Uncategorized | Entertainment/hobby-supplies suggestion | [Tie-dye and fiber-art supplies](https://www.dharmatrading.com/) |
| OCELCO INC | Uncategorized | Medical suggestion | [Medical supplies and home medical equipment](https://www.ocelco.com/) |
| TINY POWER UPS CLUB | Uncategorized | Software suggestion | [Vendor-authored description of paid Trello extensions](https://community.atlassian.com/forums/App-Central-articles/Introducing-Tiny-Power-Ups-Club-11-Power-Ups-for-just-1-per/ba-p/1947273) |
| MARIES METHOD | Uncategorized | Education suggestion; lactation training rather than patient care | [Certification and continuing-education courses](https://www.mariesmethod.com/) |
| SQ *PHX WN CURB | Uncategorized | Local transport/parking suggestion | [Exact parking-location descriptor](https://parking.com/phoenix/lot/phx-wn-curb) |
| SQ *RAMSAY CORPORATION | Uncategorized | Other suggestion: employment assessment, not necessarily education | [Employment tests and HR assessment](https://www.ramsaycorp.com/find-your-test/) |
| SKULLCANDY | Fitness | Shopping; clear category error | [Headphones, earbuds and speakers](https://www.skullcandy.com/collections/shop-all) |
| PUNCH BOWL SOCIAL | Entertainment | Single category is too specific under the current rule | [Meals and separately paid games](https://punchbowlsocial.com/faqs) |
| CABRINI BOOKSTORE #290 | Education | Provisional Shopping; bookstore identity does not establish textbooks or required materials | [Campus map identifies bookstore](https://pacac.memberclicks.net/assets/ProfDev/cabrini-college-campus-map.pdf); policy supplies the boundary |
| PAYPAL *MVSENTERTAI | Entertainment | Unresolved identity; ENTERTAI substring is insufficient | Initial and expanded-name searches did not establish a reliable merchant match |
| SQ *ROYAL TRANSPORT | Local transport | Unresolved identity; freight versus passenger service cannot be inferred | Namesake passenger and freight businesses prevent a unique match |
| GRAB | Uncategorized | Defensible abstention | [Rides](https://www.grab.com/global/rides/) and [food/delivery services](https://www.grab.com/inside-grab/product-innovation/food-and-deliveries/) |
| ONE FISH TWO FISH | Uncategorized | Unresolved merchant identity | A [restaurant](https://www.1fish2fish-dc.com/) and a [retail boutique](https://www.onefishstore.com/pages/contact) share the name |

### Dave & Buster's: separate targeted check

`DAVE And BUSTER'S INC.` is row `delaware-100-070` in the **separate historical 100-row diagnostic**, not a member of this random 200-row sample or the accepted 7,254-row split files. Its recorded rationale already says the business combines dining and arcade activities, with no indication of which was purchased. The [official site confirms both](https://www.daveandbusters.com/us/en/play/arcade/best-arcade-near-me).

The example establishes merchant identity, but it does **not** demonstrate a missed lookup or a wrong single category under the existing policy. If the desired product behavior is to suggest Entertainment or Dining for such merchants, define that as a provisional-default policy with review, or retain multiple candidates. Apply the rule consistently to Punch Bowl Social, hotels/spas and similar brands; do not silently redefine Uncategorized during evaluation.

## What this means for Qwen

**Preserve the checkpoints. Stop treating agreement with the old references as sufficient evidence to select a model.** My recommendation is to build a corrected evaluation target before another training run, and to make a fresh adapter from the original instruction-tuned base a primary candidate once the dataset is repaired. A clean restart avoids making the already adapted weights the only path forward; it is not proof they are irrecoverable.

The local packages are separate adapters over preserved base-model files:

| Package | Model ID | Prompt | What is established |
|---|---|---|---|
| `.local/macos/models/qwen` | `qwen-full-v1-step512` | v1 | Earlier transaction adapter tested in today's DDGS benchmark |
| `.local/macos/models/qwen-delaware` | `qwen-delaware-v1-step5872` | v2 | Delaware continuation from the preserved v2 step-2,080 adapter |

Both use separate `adapters/` directories, so there is no need to discard or re-download the base weights. [MLX documents separate adapter storage and optional fusion](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md). This audit did not determine which package the running app currently selects.

Two existing experiments give relevant, limited evidence:

1. The [100-row DDGS benchmark](../experiments/merchant-search/QWEN_REAL_BENCHMARK_2026-10-23.md) found category-reference agreement of **44/100 for the original model + search versus 58/100 for the earlier adapter + search**. That argues against assuming every fine-tune is worse. It used old AI references and **did not test the Delaware continuation**. Its 67 accepted search matches were not independently verified merchant identities. The benchmark's saved machine-readable manifest hash matches the current earlier package. Its prose adapter hash has a transcription omission; the local manifest and this audit's verification record contain the complete digest.
2. The Delaware continuation improved agreement with its 672 weak validation references from **60.4% to 71.6%**, while the 279-row synthetic validation category score fell from **82.1% to 73.1%**. That shows a changed tradeoff, not demonstrated improvement in real purchased-item accuracy. The old labels themselves select for the old abstention behavior.

The likely failure mechanism is a hypothesis: training many identifiable merchants as Uncategorized may reinforce abstention when useful external evidence is available. The training split contains 2,537 Uncategorized targets among 5,865 rows (43.3%). Search appends evidence at inference; it does not automatically replace learned category boundaries, guarantee that the model uses the evidence correctly, or verify the merchant match. This audit measured label quality, not the causal effect of those labels on Qwen.

### Recommended next steps

1. **Freeze the old artifacts as baselines.** Pause further training on unchanged Delaware labels. Preserve the original base, pre-Delaware adapter and Delaware adapter for comparison; no deletion or automatic model switch is warranted by this audit.
2. **Write the target policy first.** Decide when an identified merchant supports a provisional default and when multi-service ambiguity must remain Uncategorized. Store merchant identity, business type, category suggestion, evidence and review separately. Do not label every healthcare-adjacent training provider Medical, every URL Software, or every professional association Education.
3. **Build a human-adjudicated evaluation set from realistic target data.** Use fresh merchant-family-held-out examples, noisy bank strings, processor wrappers, truncated names and realistic direction/currency. Include negative and ambiguous matches and all non-expense types. Keep private bank data local unless separately authorized for external lookup. Delaware government-card merchant text alone does not establish Canadian personal-bank performance.
4. **Compare the preserved models on the same evidence and reference policy.** Test the original instruction model, pre-Delaware adapter and Delaware adapter, each with and without the same frozen search context. Use their verified compatible prompt contracts and document prompt differences; an experiment changing prompts estimates the whole pipeline, not an isolated adapter effect. Freeze settings before the final holdout. Report category/type results, supported-category macro-F1, suggestion coverage, error rate among suggestions, abstention quality, bad-match behavior and latency. Do not score legitimate evidence-driven refinements against obsolete description-only targets as automatic errors.
5. **Repair the retained training corpus with provenance.** Keep raw descriptions and original labels immutable. Add reviewed merchant evidence and separate revised targets; retain unresolved rows as valid abstentions. Prioritize recoverable Uncategorized rows, unsupported specific categories, Other and missing financial/non-expense flows. Sample an additional training-only audit if the decision requires a tighter estimate; this 200-row audit is not a category-balanced evaluation set.
6. **Train for the inputs actually deployed.** A fresh small LoRA adapter on repaired real examples should see bounded retrieved context when present, plus legitimate no-context and irrelevant/conflicting-context examples. Split merchant families before any augmentation. Use synthetic data mainly to supplement rare flows and format variation; transformations must preserve meaning. A clean `LOBLAWS #1923` example can teach a taxonomy default but cannot establish robustness to real statement formatting. Merely adding invented noise to clean examples is not a substitute for real held-out descriptions.

If a model decision must be made before that evaluation, retain the current reviewed-suggestion workflow and the existing rollback options. This audit provides no calibrated basis to declare the base model, earlier adapter or Delaware adapter the production winner. **Rebuild the evidence and target labels first; then let the controlled comparison decide whether to retire the Delaware adapter.**

## Detailed local artifacts

Detailed generated records remain ignored under `.local/delaware-web-audit-20261023-v1/`:

- `ROW_BY_ROW_REPORT.md`: all 200 descriptions, original categories, verdicts, proposed categories, rationales and selected source links.
- `audit.jsonl`: structured proposed adjudications, original answers/rationales, split membership, evidence confidence, queries and source URLs. These records are not trainer exports.
- `plan.json`, `sample.jsonl`, `summary.json`, `verification.json`: reproducible selection, aggregate counts, original-file checks and local model identities/hashes.
- `evidence-*.json`, `extra-*.json`, `opened-key-sources.json`: saved search responses and selected opened-page results for inspection. Unrelated search hits are retrieval records, not approved label evidence.

Validation checked unique sample/adjudication IDs, all 200 individual initial searches, complete original/proposed category records, verdict/category invariants, selected source URL presence in saved retrieval, aggregate reconciliation and unchanged original split hashes. No application tests were needed for a research-only report.
