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

## Uncategorized / Other / Needs review

Provide an **Uncategorized / Other** fallback when there is not enough information
to assign one of the 18 spending categories, or when a known expense does not fit
the current category set. This fallback is outside the 18 defined categories.

**Needs review** is a separate status, not a spending category. Uncategorized
transactions should enter review. A transaction with a suggested category can
also need review if the suggestion is uncertain or the purchase spans categories.

- **Uncategorized:** no supported category is available yet.
- **Other:** an expense is understood but does not fit the defined categories;
  preserve a note describing its purpose so repeated cases can inform a future
  category.
- **Needs review:** a person must confirm or correct the transaction. Keep any
  suggested category separate from the confirmed category.

Do not force an uncertain prediction into a category. Avoid training a broad
catch-all Other class that mixes unrelated expenses and missing information.

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
