# GroundKeeper labeling policy v1

Authority: `TRANSACTION_CATEGORIES.md` (18 categories), which supersedes the older
10-category Laya examples in PLAN.md. This is a public-data experiment; no label
from an AI reviewer is called human-confirmed. Labels predict what is supported
by the supplied input, not a hidden receipt or the source dataset's category.

## Contract

Input: `description` (raw bank string), `direction` (`debit`, `credit`, `unknown`),
`currency` (ISO code or null). Optional future receipt/user context must be
explicitly provided to both training and inference; it is absent in this pilot.
No source category, source identifier, model rationale, or merchant-group label
is an inference feature. A source's [debit]/[credit] marker is removed from the
raw description and exposed as direction. Do not infer direction from magnitude.

Output: {"type":TYPE,"category":CATEGORY,"review":BOOLEAN}.

Types: `expense`, `income`, `refund`, `transfer`, `card_payment`,
`loan_principal`, `cash_movement`, `balance_adjustment`, `unknown`.
Categories (stable codes -> existing display labels):

| Code | Label / boundary |
|---|---|
| groceries | Groceries: supermarkets, ingredients, grocery delivery |
| dining | Dining & takeout: restaurants, cafés, bars, prepared meal delivery |
| local_transport | Local transport: transit, taxi, rideshare, parking, tolls |
| vehicle | Vehicle expenses: fuel, charging, maintenance, registration |
| housing | Housing & home upkeep: rent, repairs, separately stated mortgage interest |
| utilities | Utilities & communications: hydro, gas, water, phone, internet |
| shopping | Shopping & household goods: retail, household supplies, electronics |
| medical | Medical & health: prescriptions, treatment, dental, optical care |
| personal_care | Personal care: cosmetics, grooming, beauty |
| fitness | Fitness & sports: gym, participation, sports equipment |
| entertainment | Entertainment & hobbies: media, streaming, games, recreation |
| software | Software & digital services: productivity, hosting, storage, domains |
| education | Education: tuition, textbooks, courses, required materials |
| travel | Travel & accommodation: flights, intercity rail/bus, lodging, rental cars |
| insurance | Insurance: explicit premiums/identifiable insurance providers |
| financial | Financial fees & interest: bank/card fees, separately stated loan interest |
| taxes | Taxes & government charges: direct tax, government admin fees, nonvehicle licences |
| gifts | Gifts & donations: charities or explicitly stated gift intent |
| other | Understood expense outside these purposes; evidence MUST name purpose |
| uncategorized | Insufficient evidence; always review=true |

## Decisions in order

1. Determine type using explicit evidence. Credit alone does not mean income or
   refund. Debit alone does not prove expense. Contradictory direction/text ->
   unknown/uncategorized/review. Explicit payroll, benefit or earnings payout ->
   income; ordinary Zelle/Interac/Venmo receipt is unknown, not income.
2. Own-account transfer must have own-account evidence; a payment rail alone
   (PayPal, Interac, Zelle, ACH) does not prove transfer or purpose. An embedded
   named merchant can still identify an expense. Opaque processor-only strings
   are unknown/uncategorized/review. Generic bank/broker name without purpose is
   insufficient. Cash/ATM withdrawal or deposit -> cash_movement, no spending.
3. Explicit card repayment -> card_payment. Explicit principal-only payment ->
   loan_principal. Generic mortgage/loan/installment payment has an unknown
   principal/interest split -> unknown/uncategorized/review. Never categorize the
   whole mortgage as housing. Mortgage interest explicitly stated -> housing;
   other borrowing interest -> financial. Nonexpense types use category=null, except `unknown`, which always uses
   category=uncategorized and review=true.
4. Explicit refund -> refund. Without original linked category, category=null and
   review=true; do not infer the original item category from its merchant. A bare
   credit at a shop is unknown/uncategorized/review, not an assumed refund.
5. For supported expenses use the most specific supported purpose. Purpose beats
   recurring format: Netflix -> entertainment, gym -> fitness, Coursera ->
   education, Notion -> software. Subscription is not a category. Do not infer a
   subscription tag from merchant alone; this pilot does not predict tags.
6. A clearly identified specialized merchant supports its usual-purpose default.
   Mixed retail (Amazon marketplace, Walmart, Costco excluding named gas/pharmacy,
   Target, Dollarama, department stores) -> expense/shopping/review=true. Never
   infer gifts, groceries, medicine or home repair from a mixed merchant alone.
   General drugstores CVS/Walgreens/Shoppers without prescription/pharmacy-service
   evidence -> expense/uncategorized/review. Apple.com/bill, Google payment and
   similar mixed digital bills without product -> expense/uncategorized/review.
7. Uber Eats -> dining; Uber Trip -> local_transport; bare Uber ->
   expense/uncategorized/review. Costco Gas -> vehicle; Costco Pharmacy explicitly
   -> medical. Home Depot/Lowe's alone -> shopping/review (goods vs repairs unknown).
   A restaurant on a trip remains dining. Sales tax stays with the purchase.
8. Monetary gifts need explicit gift text; charity donation can use identifiable
   charity/donation text. Unknown merchant/person names -> uncategorized/review.
   Do not guess a business from an unfamiliar acronym or invented synthetic name.
9. `other` is reserved for an understood expense outside the taxonomy, e.g.
   explicitly described personal legal representation or pet veterinary care.
   Do not use Other for transfers, loans, missing information, or ambiguous data.
10. `review=false` in a training label means the input supports a default under
   this policy; it does not authorize deployed model auto-acceptance. Until real
   held-out calibration exists, all model/fuzzy outputs remain suggestions.

## Annotation and audit

Each annotation records id, type, category, review, merchant_group, evidence and
`disposition` (`keep` or `reject`). Evidence is a short literal cue / boundary,
not a made-up rationale. `merchant_group` is the broadest recognizable chain or
institution; include subbrands under the parent (Amazon/AWS; Uber/Eats). Generic
payment/mortgage templates use a `generic:<purpose>` group. Never group all
PayPal/Square transactions together when an actual merchant is present.

Keep ambiguous rows when their correct answer is abstention; reject corrupt,
contradictory or unevaluable rows when no honest target can be defined. A clear
conflicting debit/payroll or debit/refund is still a useful unknown/review target.
AI reviewers read at most 25 rows per packet, process each row independently,
and cannot propagate a source category. Difficult-case audit comes first. Bulk
packets are blind to original labels. Validate enums, row IDs, types, review
invariants and completeness mechanically. Independently audit disagreements,
all Other, nonexpense, mixed merchant and low-evidence cases. Preserve original
and adjudicated labels with reviewer model and policy hash. Never manufacture
human review or confidence percentages.

Split before augmentation by canonical merchant/chain, across sources. Reject
split overlap by normalized descriptions and groups. Public references are not
confirmed personal rules. Private labels, raw datasets, checkpoints and logs
live under ignored `.local/` or `.private/`, and never enter Git.

## Difficult-case adjudications (2026-10-08)

The initial 60-case audit was reviewed by three Luna 6 agents and adjudicated by
Codex before bulk labeling. Fitbit Premium is fitness (explicit specialized
fitness service); a named dating-service subscription such as Bumble is Other,
with dating service recorded as its understood purpose. An ambiguous DMV fee is
Uncategorized because it may be vehicle registration or a nonvehicle licence.
A bare direct deposit from a company is insufficient to establish payroll.
Explicit credited interest/benefit/earnings is income. An ATM fee is financial,
not cash_movement. Credit against a principal-payment description without a
reversal explanation is unknown/review. Keep all subbrands under a shared parent
group for splitting; the purpose can still differ across subbrands.

Clarification from bulk audit: household waste collection and recycling services
are utilities. `unknown` is the explicit exception to nonexpense category=null:
it must use uncategorized/review. An unspecified subscription for a clearly named
social/dating service is Other when its outside-taxonomy purpose is understood;
a vague app-store or processor bill remains Uncategorized. Public descriptions
may be US or Canadian; country is not a training inclusion requirement.

Bank-format clarification: with debit direction, `Withdrawal from` followed by a
clearly identified specialized merchant is a purchase wrapper (e.g. US Mobile,
IMAX, Datacamp), not evidence of cash withdrawal. Remote online deposit does not
establish cash; it may be a cheque. A transfer from an account ending in digits
alone does not establish common ownership. Mixed gas/convenience retailers such
as Sheetz or QuikTrip without a fuel cue are Uncategorized/review. A generic
"Payment Thank You" without card context does not establish a card repayment.

Second blind audit adjudication: home warranty/coverage provider alone does not
establish insurance premium versus actual upkeep; use expense/uncategorized/review
unless the purpose is explicit. Bare Cricket or Aquarium without an identifying
service cue remains ambiguous. RepairClinic's parts versus repair-service purpose
is not known; preserve shopping as a provisional suggestion with review. Unknown
merchant placeholders cannot establish transaction type. A recognizable business
name may establish an expense while leaving the expense category unknown.
