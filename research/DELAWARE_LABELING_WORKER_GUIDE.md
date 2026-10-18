# Delaware 8,000-row weak-labeling worker guide

Run commands from the GroundKeeper repository root.
Read `experiments/finetune/LABELING_POLICY.md`,
`experiments/finetune/v2/POLICY_ADDITIONS.md`, and [the category policy](../docs/transaction-categories.md).
The existing type/category/review schema remains authoritative.

## Assignment and boundaries

The user explicitly requested 80 Luna 6 workers at extra-high effort, each labeling
100 distinct inputs. This authorizes 100 total per worker despite the earlier
25-input-per-labeler limit. Process those inputs as **four separate packets of
25**: never dump more than 25 input records in one tool result or rely on a bulk
merchant/category rule instead of reviewing every row.

Your task message names your worker number and stage. Your only input files are
`.local/delaware-labeling-v1/workers/NNN/inputs_01.jsonl` through
`inputs_04.jsonl`; your only output files are the corresponding
`labels_01.jsonl` through `labels_04.jsonl`. Do not edit another worker's files,
the preparation scripts, global policy, models, training data, or Git state.
Do not read any old sealed tests, the exposed diagnostic's references, other
workers' answers, source inventories, source merchant categories, model outputs,
or hidden agency/purchase context. Do not browse for purchase details.

For the `pilot` stage, process only packet 01 and then stop. For `remaining`,
preserve packet 01 and process packets 02–04. For `full`, process all four packets
one at a time. Never overwrite completed labels except when the coordinator
explicitly requests a documented correction. No worker may delegate more agents.

## What the input means

These are exact published merchant strings derived from real Delaware government
card expenditure records. The model input is **only** description, unknown
direction and null currency. Source authenticity does not establish the purpose
of a particular purchase. A descriptive merchant can support a usual-purpose
default; an opaque name or abbreviation does not justify inventing an identity.

- Named restaurants, catering, cafés and prepared-food delivery support dining.
- General retail goods, clothing, office/cleaning supplies support shopping.
  Hobby supplies support entertainment; sports equipment supports fitness.
- Mixed retailers (including Amazon marketplace, Walmart, Target, Costco) require
  shopping/review=true without an explicit narrower purpose. Home Depot/Lowe's
  alone are provisional shopping/review=true. Do not infer groceries, repair,
  medicine, gifts, or institutional/educational use from agency context.
- A named specialized provider may support its recognizable default. Preserve
  abbreviations/reference numbers as noise, not new semantic evidence. When a
  brand provides materially different services, keep the unresolved purpose
  uncategorized/review rather than guessing from a salient word.
- A bare general pharmacy or mixed digital bill lacks sufficient purpose.
  Unfamiliar companies/acronyms remain uncategorized/review. An identifiable
  business can support expense while the category is unknown; a wholly opaque
  merchant/person string can require unknown/uncategorized/review.
- Financial requires bank/card/account/borrowing evidence. A bare service or
  annual fee is expense/uncategorized/review. Government category requires an
  identifiable government entity/program or an explicit government fee. A place
  name or STATE in a company name alone is insufficient.
- `other` requires an understood service/purpose outside the taxonomy, such as
  explicit veterinary care, legal/notarial service, background-screening service,
  standalone shipping/postage/courier service. Name that purpose in the evidence.
  Never use Other for unknown merchants, ambiguous goods, transfers, or loans.
- Credit alone would not imply income/refund, and direction here is unknown.
  Never manufacture payroll, refund, own-account transfer, card repayment or
  principal-only repayment from merchant identity or a rail. Mixed installment
  or mortgage payments without a split require unknown/uncategorized/review.
- Keep valid abstentions. Reject only corrupt or genuinely unevaluable inputs;
  record why. A useful uncertain example is not a rejection.
- `review` captures decision uncertainty under the policy. It is not the app's
  forced review flag, and review=false is not calibrated automatic acceptance.

## Output contract

One JSON object per input, in the same order, with **exactly** these seven keys:

`id`, `type`, `category`, `review`, `merchant_group`, `evidence`, `disposition`.

Use JSON booleans and null. Nonexpense types have category=null, except unknown
must have uncategorized/review=true; refund without original linked purpose has
category=null/review=true. Expense requires a category. Disposition is `keep` or
`reject`. Evidence must be a short specific cue or policy boundary, not a hidden
receipt, unsupported company fact, confidence percentage or generic filler.

Merchant group is the canonical chain/parent or specific identifiable institution,
separate from the category. Group service variants and store/order-number variants
together, while allowing their purposes to differ. Use the actual embedded
merchant behind Square/PayPal/Toast; never group all transactions by processor.
For unresolved merchants use a stable `unknown:<merchant-name-without-reference>`
identifier instead of one giant unknown group. Do not merge unrelated companies
solely because names are similar. The coordinator will independently audit family
aliases and splitting before exports.

After each packet, validate it with:

```sh
.venv/bin/python -m scripts.prepare_delaware_labels validate --worker N --packet P
```

After a full/remaining assignment, validate all 100:

```sh
.venv/bin/python -m scripts.prepare_delaware_labels validate --worker N
```

Return a concise completion note with worker number, validated row count and any
unresolved policy boundaries. Do not paste all labels into chat. These outputs
are **AI weak labels**, never human-confirmed labels. No model training is part
of this job.

## Pilot clarifications

Judge the complete merchant string. A salient word is not sufficient to identify
purpose: a hotel may contain Notary, a restaurant may contain Legal, and a
publication may contain Insurance. A recognizable media subscription supports
entertainment; clinical reference software supports software. Generic or truncated
insurance/event/association wording does not establish an insurance premium.
Do not infer an unfamiliar merchant's identity; retain a justified abstention.

A clearly identified court, municipality, or government licensing board supports
taxes/government fees without requiring the specific filing or licence. A generic
COURT place-name does not. Review reflects uncertainty in the label decision;
lack of a receipt alone does not force review for an identifiable specialty
provider. General retail pharmacies remain ambiguous; recognizable clinical
healthcare providers can support medical. A processor plus a truncated university
name does not necessarily establish the underlying fee purpose. Compound
FEES/PUBLICATIONS without a clear purchased item may remain uncategorized.

## Independent audit when explicitly assigned

Some task messages also assign a separate 25-row blind audit. This is additional
quality review of another worker's inputs; it does not change your 100 primary
assignments. Read ONLY `.local/delaware-labeling-v1/audits/NNN/inputs.jsonl`
and independently write the same seven-key contract, same order, to
`audits/NNN/labels.jsonl`. Do not read the original worker's labels. Validate with
`.venv/bin/python -m scripts.prepare_delaware_labels audit-validate --worker N`.
The coordinator prepares audit inputs; you must not invoke audit-prepare yourself
because it reads original annotations. No audit is assigned unless the task
message explicitly says its inputs are ready.
