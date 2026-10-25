# Transaction categories

GroundKeeper starts with 18 spending categories. These describe the purpose of
spending; transaction type, recurring-payment properties, and review status are
tracked separately.

| # | Category | What belongs here |
|---|---|---|
| 1 | Groceries | Supermarket food, ingredients, grocery delivery |
| 2 | Dining & takeout | Restaurants, cafés, bars, fast food, meal delivery |
| 3 | Local transport | PRESTO, public transit, taxis, rideshares, parking, tolls |
| 4 | Vehicle expenses | Fuel, charging, repairs, maintenance, registration |
| 5 | Housing & home upkeep | Rent, home repairs, maintenance; mortgage interest when separately known |
| 6 | Utilities & communications | Electricity, water, heating, internet, mobile phone |
| 7 | Shopping & household goods | Clothing, electronics, furniture, appliances, cleaning supplies, general retail |
| 8 | Medical & health | Prescriptions, dental care, medical appointments, treatment |
| 9 | Personal care | Haircuts, skincare, cosmetics, grooming, beauty services |
| 10 | Fitness & sports | Gym memberships, fitness classes, sports participation and equipment |
| 11 | Entertainment & hobbies | Streaming, games, concerts, cinema, recreational activities, hobby supplies |
| 12 | Software & digital services | Productivity software, cloud hosting, storage, domains, developer tools |
| 13 | Education | Tuition, textbooks, courses, exam fees, required learning materials |
| 14 | Travel & accommodation | Flights, intercity travel, hotels, vacation rentals, rental cars |
| 15 | Insurance | Auto, tenant, home, life, and health insurance premiums |
| 16 | Financial fees & interest | Account fees, card annual fees, overdraft fees, borrowing interest |
| 17 | Taxes & government charges | Direct tax payments, licences, administrative government fees; exclude vehicle registration |
| 18 | Gifts & donations | Charitable donations, monetary gifts, purchases explicitly identified as gifts |

## None, Other, and Needs review

**None** means no category has been selected. It is stored as SQL `NULL`, not a
category row, and appears as muted text without a provenance icon. A purchase or
refund with no category stays in review.

**Other** is the nineteenth category. AI uses it when the spending purpose is
uncertain or falls outside the 18 named categories. Uncertain decisions always
require review; optional notes can explain the expense. Income, transfers, card
payments, loan principal, cash movements and balance adjustments have no spending
category. AI refunds without an original category use Other with review required.

**Needs review** is independent of category. Every AI suggestion requires review.
The UI shows a brass person for a user choice and a purple sparkle for an AI
choice. Hovering over the category identifies the saved provider/model or AI
Council. Accepting a suggestion appends a user assignment while retaining its AI
history. Editing unrelated fields preserves the original attribution.

## Labeling rules

- Use the most specific purpose supported by the available information. An
  online course is Education even though it is delivered digitally.
- Merchant-based labels are defaults, not proof of the purchased items. Mixed
  retailers such as Amazon or Costco may support only a provisional Shopping &
  household goods suggestion; use receipts or user corrections for specificity.
- Split purchases across categories when item-level information is available.
- Keep coffee within Dining & takeout and clothing/electronics within Shopping &
  household goods initially. Add subcategories when useful and supported by data.
- Sales tax included in a purchase stays with that purchase's category.
- Apply Gifts & donations to purchased gifts only when gift intent is known.
- A correction to one purchase must not automatically become a merchant-wide
  rule, especially for mixed retailers.

## Separate properties and transaction types

Subscription, recurring bill, business use, reimbursement eligibility, and trip
membership are separate properties or tags. For example, Netflix is Entertainment
& hobbies with a Subscription tag; a gym membership is Fitness & sports with a
Subscription tag. A restaurant meal on vacation remains Dining & takeout with a
trip tag.

Income, refunds, own-account transfers, credit-card payments, loan principal,
cash movements, and balance adjustments are separate transaction types rather
than additional spending categories.

- Refunds offset the original spending category when known.
- Own-account transfers and credit-card payments must not double-count spending.
- Loan principal is tracked separately from interest.
- Cash withdrawals do not reveal what the cash was subsequently spent on.
- Payment method alone does not establish purpose: an Interac e-Transfer could
  represent rent, reimbursement, a gift, or an own-account transfer.

## Research references

- [Plaid category design](https://plaid.com/blog/transactions-categorization-taxonomy/)
- [Plaid personal finance category documentation](https://plaid.com/docs/transactions/pfc-migration/)
- [Monarch default categories](https://help.monarch.com/hc/en-us/articles/360048883851-Default-Categories)
- [Monarch transaction tags](https://help.monarch.com/hc/en-us/articles/4409690120596-Organizing-Transactions-with-Tags)
- [YNAB income and refund guidance](https://support.ynab.com/en_us/how-to-add-income-and-other-inflows-H1ZNjfZJi)
