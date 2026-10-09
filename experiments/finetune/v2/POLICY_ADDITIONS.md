# Frozen clarifications for v2 labeling

Read ../LABELING_POLICY.md first. The category/type enums and separation of Other,
Uncategorized and review remain unchanged. These clarifications were adjudicated
after three blind 25-row audits of difficult/rare training examples.

- Review concerns uncertainty about the requested decision. An unfamiliar payer
  name or a concatenated bank field does not by itself require review when an
  explicit payroll, benefit, interest, refund or fee cue establishes the decision.
  A clearly anomalous or contradictory input may instead be rejected; retain a
  documented rejection reason. Credit alone never establishes income.
- A credit explicitly marked payroll/salary, benefits, earnings payout or savings
  interest is income with category=null. A merchant name that merely contains a
  payment-related word does not establish that purpose. Punctuation/case changes
  must not change the decision. Do not use unseen source-category information.
- DAILY CASH ADJUSTMENT explicitly supports balance_adjustment/category=null.
  It does not establish a physical cash withdrawal/deposit. ATM CASH WITHDRAWAL
  supports cash_movement/category=null. Clearly stated own-account transfers,
  credit-card repayments and principal-only payments use their distinct types.
- A debit bank wrapper 'withdrawal from' followed by an identifiable merchant
  is not an ATM cue. Use the merchant/service purpose if identifiable; otherwise
  abstain. Never infer ownership of accounts from a rail or bank name alone.
- A standalone SHIPPING FEE / courier-delivery charge has an explicit outside-
  taxonomy service purpose: expense/other. It does not reveal the category of an
  unspecified underlying purchase. Do not relabel an entire retail purchase as
  Other merely because it might include shipping.
- Taxes requires a recognizable government program or explicit tax/government-
  fee purpose. 'Global Entry LLC' does not establish the government program and
  remains expense/uncategorized/review. Bare 'Clear Enrollment' cannot resolve
  which enrollment/service is meant and retains unknown/uncategorized/review.
- Preserve specialized-merchant defaults only when the merchant is identifiable.
  Explicit purpose takes priority over words in an address (e.g. University Rd),
  processor prefix, or incidental city name. Household waste/recycling is utilities.
- Mixed retail has provisional shopping/review=true. Bare general drugstores,
  unspecified digital bills, and service-ambiguous brands require review. No
  inferred gift intent, hidden receipts, or fabricated numeric confidence.

Every labeler sees at most 25 inputs. Use exactly id,type,category,review,
merchant_group,evidence,disposition. Nonexpense categories are null except unknown
uses uncategorized/review=true; refund without an explicit original linked
purpose uses null/review=true. Evidence must point to supplied text or the precise
policy boundary. Use keep for valid abstentions; reject corrupt unevaluable text.

Merchant identity and split metadata are distinct from category. If a bank or
other institution is explicitly identified, name that institution in merchant_group
even when the transaction is a transfer, fee or principal payment. A generic
purpose does not turn every bank's transactions into one merchant. Unknown rails
or truly generic narrations remain generic and their variants must stay together.
Authored synthetic records and public source records are never human confirmations.
