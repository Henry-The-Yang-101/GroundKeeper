# Public-data audit

## Initial difficult-case audit

Completed before bulk labeling: 60 public synthetic rows, three independent Luna
6 agents with 20 rows each, followed by parent Codex review of every decision.
These are AI-reviewed labels, not human ground truth. Raw inputs and original
annotations remain in ignored `.local/finetune/audit/`.

Observed errors and mismatches in the source: explicit refunds labeled Income;
credits described as fees; Zelle/Venmo receipts treated as income without evidence;
whole mortgage and installment payments lacking a principal/interest split;
CVS assigned medical without pharmacy evidence; Apple bills concealing product;
gym fees in Personal Care; streaming/productivity/fitness subscriptions mixed in
one class. Direction and bank formatting can contradict the synthetic purpose.

Resolved boundary cases in LABELING_POLICY.md before bulk review: general
pharmacies, dating apps, Fitbit, DMV fees, direct deposit, ATM fees, mixed retail,
refunds, mortgages, and processor wrappers. Abstention examples are retained as
useful targets, rather than forcing source categories into the new taxonomy.

## Verified source snapshot

- DoDataThings/us-bank-transaction-categories-v2, MIT, revision
  `3e8d052cb7b362fb1a04b6064d2331982553ea56`: downloaded CSV has exactly 68,000 rows,
  17 source categories with 4,000 each, fields description/category. Synthetic,
  US-oriented. No blanket source-to-project mapping is valid.
- mitulshah/transaction-categorization, MIT, revision
  `8597493f0aaa44c540c16458b18b17e4ada2f5cc`: gated, unauthenticated access returned
  401. Card reports 4,501,043 generated rows, 10 coarse categories and country/
  currency fields, including Canada. Counts are not locally verified. Awaiting
  user terms acceptance/login; no workaround or copied mirror used.
- crossingminds/credit_card_3k, MIT, revision
  `dcb5e807abb9cce5858ebcfee509c224c85bb860`: author describes LLM-generated
  merchant pairs reviewed/corrected by author. Merchant evaluation only. Card
  prose and metadata disagree on split counts; use actual file counts. Not real
  held-out Canadian transactions, and not category training data.
- Mendeley MoneyData v1, DOI 10.17632/dnxtg6n4rv.1, CC BY 4.0, published Jan 14,
  2026. Page describes >6,500 anonymized real retail transactions over seven
  years from July 2015, with date/type/description/debit/credit/balance. This is
  optional external evaluation, not a reviewed Canadian corpus. File suitability
  and exact count remain to be inspected; not used in training.
- Foursquare fsq-os-places, Apache-2.0, revision
  `cac305a8887e949391fc607fed67c79d3338669d`: gated merchant metadata, not category
  labels. Overture Places likewise supplies POI metadata with source-dependent
  attribution, not bank transactions. Neither bulk global dataset is downloaded.

Source links: [DoDataThings](https://huggingface.co/datasets/DoDataThings/us-bank-transaction-categories-v2),
[Mitul Shah](https://huggingface.co/datasets/mitulshah/transaction-categorization),
[Crossing Minds](https://huggingface.co/datasets/crossingminds/credit_card_3k),
[MoneyData](https://data.mendeley.com/datasets/dnxtg6n4rv/1),
[Foursquare](https://huggingface.co/datasets/foursquare/fsq-os-places),
[Overture](https://docs.overturemaps.org/guides/places/).

## Ungated replacement search

After login, Mitul still returned 403 (not in authorized list). User requested an
ungated alternative, so it is excluded. Live Hugging Face API counts on this run
showed DoDataThings v2 at 431 monthly downloads versus Mitul at 213; the existing
primary source is already more downloaded on that metric. Popularity is not a
quality measure. Additional candidates inspected:

- utkarshugale/BusinessTransactions: ungated, CC BY 4.0 in card and LICENSE,
  revision `d73a8a0b8d9689ea39740cface8b1656e774e6d6`, 55 monthly downloads. Actual
  CSV contains 17,471 rows (card claims 17,667), Qwen-generated US business
  descriptions from Foursquare names/categories. At least 29 rows contain
  generation artifacts by a narrow regex. Random 50-row suitability sample
  retained locally. Many descriptions disclose invented line items/amounts;
  a poor distribution match for bare Canadian bank strings. Not added to training.
- mindweave/bank-transactions-us: 133 monthly downloads, CC BY-NC 4.0, simulated
  business-account records, rather than personal Canadian spending. Excluded.
- Sumeetgpt/indian-transaction-categorization-synthetic: 79 monthly downloads,
  MIT, card reports 970 synthetic rows. Indian UPI/NEFT narration and merchants
  are not a replacement for Canadian coverage. Excluded from this pilot.
- Broad Kaggle fraud/payment datasets are not automatically merchant-category
  text data. They were not substituted solely for popularity or row count.

No stronger ungated Canadian category source was verified. The experiment uses
an audited DoDataThings pilot plus 100 explicitly authored Canadian synthetic
inputs, blind-labeled separately. Those inputs are a policy/coverage diagnostic,
not collected Canadian transactions, not human-reviewed ground truth, and not
proof of real-world accuracy. The 1,000 real Canadian evaluation target remains
unfilled. Public merchant pairs stay separate from category training.
