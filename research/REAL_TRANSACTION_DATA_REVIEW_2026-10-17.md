# Real Canadian/US transaction source review — 2026-10-17

Status: **awaiting Henry's dataset review**. No labeling, split construction,
model inference, training, checkpoint changes, or existing test-set access.

## Recommendation

Use British Columbia's purchasing-card disclosures as the Canadian merchant-text
source and Delaware's state employee card transactions as the US complement,
subject to review of their domain limitations. Both have identifiable government
publishers and explicit reuse designations. They offer enough distinct merchant
strings to propose a new, independently reviewed batch without more synthetic
generation.

**These are government purchasing-card records, not a representative collection
of personal chequing-account statements.** They support a real merchant/card
description benchmark; they cannot by themselves establish household banking
accuracy or fill all fee, transfer, loan, and income boundaries. I did not find
a public personal-banking corpus with verified Canadian/US origin, appropriate
reuse terms, and independently human-reviewed labels for our input contract.

## Recommended sources

### 1. British Columbia: Purchasing Card Transaction Account Expenditures

- [Official catalogue](https://catalogue.data.gov.bc.ca/dataset/purchasing-card-transaction-account-expenditures)
  and [federal catalogue mirror](https://open.canada.ca/data/en/dataset/8d1df6c4-a342-4b4d-aca7-1daff643ed0f?res_page=1).
- Publisher: Government of British Columbia; data covers ministry card purchases.
- Catalogue licence: **Open Government Licence – British Columbia**.
- [April–June 2026 CSV](https://catalogue.data.gov.bc.ca/dataset/8d1df6c4-a342-4b4d-aca7-1daff643ed0f/resource/4eb5acb8-8c52-4b96-b5cb-36d7ebe662f2/download/pcard-qpa-report-april-jun-2026.csv).
- Directly counted: **38,321 rows; 12,497 distinct merchant strings; 2,921,809
  bytes; no empty merchants; every `Count` is 1; 1,177 negative-amount rows**.
- Columns: `Merchant`, `Count`, `Amount`, `City`, `Province`, `Ministry`.
- Exact public examples: `Amzn Mktp Ca`, `Telus Mobility Preauth`,
  `Real Cdn Superstore #1`, `Paymentus-Service-Fee`, `Associated Veterinary`.
- More annual/quarterly files are listed; only this quarter was fully profiled.

The text retains abbreviations and merchant/processor conventions, but the source
does not establish byte-for-byte fidelity to personal bank exports. There are no
category labels, transaction dates, currency codes, or account identifiers in
this selected file. Distinct strings are **not** distinct merchant families.
For example, Staples Professional/7 occurs 2,709 times. The jurisdiction is
Canadian, but purchases include foreign merchants. Negative amounts require
review; they are not automatically confirmed refunds.

### 2. Delaware: State Employee Credit Card Transactions

- [Official dataset](https://data.delaware.gov/Government-and-Finance/State-Employee-Credit-Card-Transactions/nurt-5rqw)
  and [machine-readable metadata](https://data.delaware.gov/api/views/nurt-5rqw.json).
- Publisher: Department of Finance, Division of Accounting.
- Metadata licence: **Public Domain**, `licenseId=PUBLIC_DOMAIN`.
- Live API counts: **2,251,316 rows; 436,557 distinct merchant strings; 504
  distinct source category strings; dates 2014-05-07 through 2026-09-28**.
- A practical recent slice, dates from 2024-01-01: **531,100 rows; 134,980 distinct
  merchant strings; 249 source category strings**.
- Fields include `merchant`, `cat_descr`, `trans_dt`, `merchandise_amt`, fiscal
  year/period and department/division. `cat_descr` describes the merchant's
  category as identified to the card company, not independently reviewed
  GroundKeeper labels.
- Exact public examples: `SQ *AIRPORT TAXI 66`, `PAYPAL *DELAWAREBIO`,
  `SQ *CARROLL'S HANDYMAN SE`.
- Source category variants together contain **2,233 veterinary**, **776 legal**,
  and **2,392 insurance sales/underwriting/premium** rows. These are sampling
  leads, not validated targets or coverage guarantees.

This is transaction-level institutional card spending with no cardholder field
in the published schema. Merchant strings can contain processor noise. Category
capitalization variants inflate the category count; order/reference variants
inflate merchant counts. Source categories may reveal information absent from
the merchant string, so they must not become either inference features or
unreviewed labels. Government veterinary/legal purchases also do not necessarily
share the purpose of personal veterinary/legal expenses.

## Fit to the requested improvements

| Need | What this shortlist supplies | Remaining gap |
| --- | --- | --- |
| Real Canadian/US descriptions | Published merchant text from actual card expenditure records | Personal bank narration and household distribution |
| New merchants, abbreviations, wrappers | Many strings, including Square, PayPal and abbreviated merchants | Deduplication and merchant-family review are still required |
| Other | Veterinary/legal source categories and some explicit merchant cues | Human adjudication using only permitted inputs; opaque firms may require abstention |
| Standalone fees vs financial charges | Explicit service-fee strings and nonfinancial merchant fee categories | Bank/card interest, overdraft and ambiguous standalone fee coverage is not established |
| Insurance | Source-tagged insurance merchants | A generic payment or institution must not imply a premium |
| Loan principal, transfers, income | Little direct support from these card sources | A separate consented personal-banking collection is still needed |
| Human ground truth | No GroundKeeper human-reviewed labels yet | Independent human review before a real evaluation set is claimed |

## Other leads checked

| Source | Finding | Decision |
| --- | --- | --- |
| [Oklahoma payment cards](https://oklahomastate.opengov.com/data/) / [official FY2014 catalogue](https://catalog.data.gov/dataset/purchase-card-pcard-fiscal-year-2014) | Official government card source; current portal advertises about 9 million rows with merchant, item and merchant-category text | Additional US lead; not selected because Delaware has a directly verified public-domain designation and queryable metadata. Item descriptions must not leak hidden purchase context |
| [gbadedata/transaction-classification](https://github.com/gbadedata/transaction-classification) | Publisher reports about 259,000 US-style transactions; explicitly says origin is unverified and no data licence can be asserted | Do not treat as verified-real benchmark or import for training. MIT applies to its code, not established rights to its data |
| [Maaz-Zaidi RBC benchmark](https://github.com/maaz-zaidi/transaction-classifier) | Author reports 505 unique RBC strings / 3,113 weighted occurrences. Evaluation file is named `openai_labeled.csv`; `data/real/` is not included | Relevant Canadian lead but unavailable publicly and not documented as independent human ground truth. No author was contacted |
| [MoneyData/MoneyVis](https://data.mendeley.com/datasets/dnxtg6n4rv/1) | Research release reports 6,500+ anonymized real retail transactions, seven years from July 2015, CC BY 4.0 | Backup only; Canadian/US geography and suitability of anonymized merchant text were not established from the landing page |
| [Kaggle Personal Finance](https://www.kaggle.com/datasets/bukolafatunde/personal-finance) | Original API metadata says it came from a Davidson course and lists licence Unknown. Another uploader claims 806 real-world records and MIT | A mirror's claims do not establish the original provenance or reuse rights; not selected |
| [DoDataThings v2](https://huggingface.co/datasets/DoDataThings/us-bank-transaction-categories-v2) | Synthetic bank-format examples, already part of our synthetic-data context | Not a new real dataset |
| [Mitul Shah](https://huggingface.co/datasets/mitulshah/transaction-categorization) | Card describes millions of template-generated records plus unspecified external real data; no per-row origin in its four-field schema | Not acceptable as a separately verified real evaluation corpus |
| [USA Banking Transactions 2023–2024](https://www.kaggle.com/datasets/pradeepkumar2424/usa-banking-transactions-dataset-2023-2024), [Mindweave](https://huggingface.co/datasets/mindweave/bank-transactions-us), [GoMask](https://gomask.ai/marketplace/collections/bank-transaction-datasets) | Descriptions/cards identify generation or simulation despite realistic/real-world wording | Synthetic; rejected for this stage |

## What happens only after dataset review

1. Agree whether the institutional-card domain is useful enough as a first real
   batch. Keep a separate consented personal Canadian banking corpus as a
   requirement for eventual deployment evaluation.
2. Freeze source versions, retain provenance, remove irrelevant fields, and
   deduplicate/cap related merchant strings. Review currency and sign semantics;
   do not manufacture missing context. Do not use agency, MCC/source category,
   item descriptions or private purchase knowledge as model inputs.
3. Assign merchant families across sources and existing data. Reserve a real
   evaluation pool outside all training and tuning before selecting a training
   batch. Split construction must respect existing held-out families without
   opening the existing sealed test to inspect its errors.
4. Have humans independently review actual supported `type/category/review`
   labels under `experiments/finetune/LABELING_POLICY.md`. Preserve ambiguity;
   Amazon alone cannot identify groceries. Agent proposals remain weak labels.
5. Resume continuation comparisons from the current selected Qwen v2 and Laya
   checkpoints, keeping one change at a time and using validation only for
   selection. Follow the requested lower-rate/regularization comparisons before
   larger adapters, extra layers or longer training, then consider SetFit.
6. Run the proposed 500/1,000/2,077 learning-curve comparison with merchant-grouped
   subsets and one fixed validation set. **For a clean original-data learning
   curve, use the same pre-finetune base for every subset:** the current fine-tuned
   checkpoints have already seen all 2,077 rows. Continuing those checkpoints
   cannot test the effect of withholding part of their original training data.
   Test the genuinely new batch separately as an incremental-data experiment.

## Verification and boundaries

Evidence is in [REAL_TRANSACTION_SOURCE_EVIDENCE_2026-10-17.json](REAL_TRANSACTION_SOURCE_EVIDENCE_2026-10-17.json),
including URLs, the Canadian file checksum, query definitions and measured
counts. BC was read into memory to profile one 2.92 MB file; Delaware was checked
with aggregate queries and small public previews. Other sources were checked
through metadata, repository trees and documentation. No bulk corpus was saved
or added to training, no new labels were assigned, and no model job was started.
Counts describe publisher data at review time, not a frozen reviewed dataset.
Licence names above are publisher metadata, not independently adjudicated rights
to every record. The BC licence page itself could not be retrieved; its explicit
catalogue designation was retrieved successfully.
