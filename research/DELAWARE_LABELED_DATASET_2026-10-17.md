# Delaware 8,000-description weak-label dataset

Completed **8,000 primary annotations** with **80 Luna 6 (`gpt-6-luna`) xhigh workers**, 100 distinct descriptions each in four packets of 25. There are **2,000 additional blind second reviews**. **Zero labels are human-confirmed. No training was started.**

Both existing models were trained on the **same 2,077 unique synthetic, AI-reviewed transactions**. Laya expands each transaction into three decision items (6,231 per epoch); this does not mean 6,231 unique transactions. Its selected checkpoint is epoch 3. Qwen v2 configuration also records 2,077 training rows. See `experiments/laya/training_report.json` and `experiments/finetune/v2/training_config.json`.

Retained **7,254** descriptions; quarantined **746**.

| Split | Transactions | Merchant families |
|---|---:|---:|
| train | 5,865 | 5,282 |
| valid | 672 | 645 |
| test | 717 | 681 |

Quarantine reasons:

- diagnostic_or_historical_holdout_family_overlap: 174
- independent_review_disagreement_pending_adjudication: 571
- normalized_description_already_in_old_training: 1

Blind reviewers initially agreed on the complete decision and disposition for 1,416/2,000 (70.8%). This is AI agreement on an intentionally boundary-heavy sample, not accuracy. Unresolved reviewed disagreements are excluded. Unreviewed rows remain weak labels.

Family unions join provisional selection groups, annotator groups, recognized raw-text aliases and independent reviewer groups. Known historical holdout and earlier 100-row diagnostic families are quarantined; old training families can enter only training. No recognized family crosses the new splits. Ownership aliases are not exhaustive.

Additional chain aliases were checked against official portfolios: [Kroger](https://www.thekrogerco.com/about/history/), [TJX](https://www.tjx.com/company/about-tjx), [Hyatt](https://newsroom.hyatt.com/hyatt-hotels-corporation-fact-sheet), [Marriott](https://www.marriott.com/brands.mi), [Hilton](https://www.hilton.com/en/portal/travel-agents/gds-information/), [Wyndham](https://corporate.wyndhamhotels.com/our-brands/wyndham-hotels-resorts/), and [Choice](https://www.choicehotels.com/choice-brands). These aliases affect splitting only; category labels remain based on the visible input.

## Files

These paths identify generated local artifacts, which are excluded from Git.
The [runbook](../experiments/finetune/delaware-v1/RUNBOOK.md) records their
preparation and verification requirements.

- Export guide: `.local/delaware-labeling-v1/prepared/README.md`
- Counts, provenance, limitations and hashes: `.local/delaware-labeling-v1/prepared/manifest.json`
- Training records with evidence: `.local/delaware-labeling-v1/prepared/train.canonical.jsonl`
- Validation records with evidence: `.local/delaware-labeling-v1/prepared/valid.canonical.jsonl`
- Qwen v2 training format: `.local/delaware-labeling-v1/prepared/train.qwen.jsonl`
- Qwen v2 validation format: `.local/delaware-labeling-v1/prepared/valid.qwen.jsonl`
- Laya training format: `.local/delaware-labeling-v1/prepared/train.laya.jsonl`
- Laya validation format: `.local/delaware-labeling-v1/prepared/valid.laya.jsonl`
- All 8,000 original primary annotations: `.local/delaware-labeling-v1/prepared/all_annotations.jsonl`
- Rows excluded pending review or because of family overlap: `.local/delaware-labeling-v1/prepared/quarantine.jsonl`
- Independent review disagreements: `.local/delaware-labeling-v1/prepared/audit_disagreements.jsonl`

The new real test is `test.canonical.jsonl`, read-only and absent from trainer-facing exports. Keep it outside training; obtain independent human review before using it as a gold accuracy benchmark.

## Verification

- qwen: export targets match canonical records; maximum sequence 479/512 tokens, no truncation. Check result: `.local/delaware-labeling-v1/verification/qwen.json`.
- laya: export targets match canonical records; maximum sequence 293/512 tokens, no truncation. Check result: `.local/delaware-labeling-v1/verification/laya.json`.

No inference or training was used in these checks; the new sealed test was not parsed.

## Coverage

| Category | Retained rows |
|---|---:|
| dining | 2,012 |
| education | 163 |
| entertainment | 168 |
| fitness | 58 |
| gifts | 7 |
| groceries | 52 |
| housing | 33 |
| insurance | 7 |
| local_transport | 209 |
| medical | 93 |
| other | 56 |
| personal_care | 14 |
| shopping | 758 |
| software | 87 |
| taxes | 35 |
| travel | 263 |
| uncategorized | 3,110 |
| utilities | 29 |
| vehicle | 100 |

Categories absent: financial. Types absent: balance_adjustment, card_payment, cash_movement, income, loan_principal, refund, transfer.

## Provenance and limits

Exact published merchant strings from [Delaware official card expenditure data](https://data.delaware.gov/resource/nurt-5rqw.json), [metadata](https://data.delaware.gov/api/views/nurt-5rqw.json). The frozen inventory contains 436,557 distinct strings. Source categories, agencies, amounts, and dates were not labeling features; input is description, unknown direction, and null currency. Selection prioritizes merchant diversity and includes 75 targeted pilot rows; it is not a uniform transaction sample. These are real institutional US card merchant descriptions, not representative Canadian personal banking narrations.

The pilot caught ambiguous merchant titles. Public merchant-identity references included [Business Insurance publication](https://www.businessinsurance.com/about/), [The Notary Hotel](https://www.marriott.com/hotels/travel/phlak-the-notary-hotel-philadelphia-autograph-collection/), and [Plumb’s reference software](https://plumbs.com/pricing/). These establish merchant identity, not hidden purchase contents. Original labels and independent pilot references remain preserved alongside separate coordinator adjudications.

Use this as weak supervision after inspecting labels and class balance. It cannot establish production accuracy or resolve the contents of a mixed-retailer purchase.
