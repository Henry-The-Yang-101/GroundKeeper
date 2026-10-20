# User receipt regression cases

These cases preserve labels supplied by the user, independently of what the
models predict. They are separate from the fixed 20-receipt SROIE pilot and do
not change its published denominator. Sanitized fixtures can be committed;
original photos, identifiers and private description overrides stay in `.local`.

## Costco grocery basket — October 20, 2026

Expected: **expense / groceries**, explicitly specified by the user. Actual
Shortcuts Extract Text from Image completed on the uploaded photograph in
542.7 ms on the Mac. The recognized text includes granola, doughnuts, macarons,
chicken, tzatziki, cereal, grapes and basmati rice, as well as other item names.
OCR spelling is preserved. Membership and location lines were removed and long
identifiers redacted before the receipt text entered either model.

The live run used the exact transaction wording and bank reference from the
screenshot, flattened to one line. The committed fixture replaces that reference
with `[identifier]`. Both variants used the same description, debit direction and
CAD currency; only the enriched variant included receipt context. Model inputs
did not include the expected label. Images and exact identifiers were not added
to Git. The [recorded results](../results/2026-10-20-user-costco.json) contain input
hashes, model identities, decisions and errors without the private input text.

| Actual model | Description only | With actual receipt OCR | Matches groceries? |
| --- | --- | --- | --- |
| Qwen, qwen-delaware-v1-step5872 | expense / shopping | expense / shopping | Neither variant |
| Apple Intelligence, GK Categorize Cloud | expense / shopping | expense / shopping | Neither variant |

All four requests returned valid, reviewable predictions. There were no service
errors. Receipt context did **not** improve this case: category matches were 0/1
without and 0/1 with the receipt for each model. One example is a pass/fail
regression observation, not a useful success-rate estimate. Keep groceries as the
expected answer; do not relabel this case shopping to match model output.

The existing description prompt explicitly includes `Mixed retail=>shopping`,
and receipt instructions also direct mixed baskets to shopping. This is a
plausible contributor, not a verified explanation of either model's decision.
The receipt includes VITAFUSION and other ambiguous product names alongside
food. A future policy change should distinguish merchant breadth from purchased
items, define handling of predominantly grocery baskets, and be evaluated on
held-out cases rather than optimized solely to make this example pass. No
prompts, weights or category rules were changed during this test.

The subsequent [OCR audit](COSTCO-OCR-AUDIT.md) checked all visible items,
discounts, totals and native table cells. Item evidence survived, but the footer
was misaligned and the grand total lost its decimal point. Those are recorded
extraction defects, separately from the categorization miss.

The receipt total and transaction amount differ. This test uses the pair only
to evaluate the requested category. It does not prove they belong to the same
purchase, create a ledger attachment, or change either monetary amount. The
classification contract does not send payment amount, so this discrepancy is
recorded separately from model output.

## Run the case

```sh
.venv/bin/python -m scripts.receipt_case experiments/receipts/user-cases/costco-groceries.json --provider qwen --package .local/macos/models/qwen-delaware --work .local/receipts/costco-new-run
.venv/bin/python -m scripts.receipt_case experiments/receipts/user-cases/costco-groceries.json --provider apple --work .local/receipts/costco-new-run
```

These commands use the sanitized fixture description. For the original private
description, add `--description-file .local/receipts/user-costco/transaction.txt`
on this machine. Apple runs explicitly send this case to the selected installed
Shortcut/model; verify its model selection before testing. Use a new work folder
for every repeat. Existing reports are never overwritten. Add `--require-correct`
to make a model integration check exit unsuccessfully when either variant misses
the label. The current recorded run is a known model regression.

The ordinary offline test in `tests/test_receipt_cases.py` checks fixture input
validity, the groceries label, evidence isolation and absence of label leakage.
It does not load model weights or spend Apple Cloud quota, and passing that test
does not imply that the models categorized this case correctly.
