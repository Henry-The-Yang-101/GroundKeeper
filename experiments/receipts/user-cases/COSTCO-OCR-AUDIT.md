# Costco receipt OCR audit — October 20, 2026

The OCR preserves the purchase items well enough to supply useful category
evidence. It does **not** produce trustworthy structured receipt totals. Current
production output is a flat transcript, producer, elapsed time and table count;
there are no validated item, discount, subtotal, tax or total fields.

## What was tested

Reran the actual installed GK Receipt OCR action and the production native Vision
reader on the original uploaded image. Also ran the same default native document
request in a diagnostic Swift script to inspect table cells rather than only the
flattened transcript. No image edits, model requests or prompt changes were made.

The [reference](costco-ocr-reference.json) is an assistant's manual visual
transcription of the photograph, not independent OCR ground truth. It contains
16 item names/SKUs/prices, four discounts, and the visible footer amounts.
It excludes membership, address and banking identifiers. The reference reconciles:
item prices 233.64 minus discounts 14.00 equals subtotal 219.64; adding tax 8.57
equals total 228.21. Original images, full raw OCR and native table dumps remain
in the ignored `.local/receipts/user-costco` directory.

## Item evidence

| Check against the photograph | Actual Shortcuts OCR | Production native Vision |
| --- | ---: | ---: |
| Product SKUs present, allowing punctuation in digits | 16/16 | 16/16 |
| Exact item-name text, ignoring whitespace | 13/16 | 13/16 |
| First following item price matches reference | 16/16 | 16/16 |
| SKU-linked negative discount amounts match | 4/4 | 4/4 |

The native document reader detected one table with 25 rows. Its table cells also
contained all 16 item SKUs with the correct prices in the same rows. This is a
separate check from scanning for the next price in a transcript. It is not a
claim that our production app currently emits structured item records.

The exact-name errors are identical in both paths:

| Visible receipt text | OCR text |
| --- | --- |
| CH CHICKEN | CH CHIRKEN |
| CIN TST 1.3K | CIN IST 1.3K |
| RAISIN BRAN | KAISIN BRAN |

Other food evidence, including granola, grapes, doughnuts, macarons, tzatziki,
snack cups and basmati, survives. The fresh Shortcuts run corrected the earlier
logo reading EWHOLESALE to WHOLESALE; the item and footer findings were unchanged.
Observed rerun times were about 751 ms for the Shortcuts CLI and 584 ms for native
OCR. These are single Mac runs, not iPhone or general performance estimates.

## Footer failures

Both flat transcripts end with this ordering:

```text
SUBTOTAL
TAX
219.64
**** TOTAL
8.57
CASH
22821
0.00
```

The image instead pairs SUBTOTAL with 219.64, TAX with 8.57, TOTAL with 228.21,
and CASH with 0.00. The decimal point in the grand total is missing, and labels
and amounts have become misaligned. A label/next-line parser would misread them.

The underlying Vision table has the same problem:

| Native table's label cell | Native table's value cell |
| --- | --- |
| SUBTOTAL | empty |
| TAX | 219.64 |
| **** TOTAL | 8.57 |
| CASH | 22821 followed by 0.00 |

Preserving these table cells alone would therefore not fix footer extraction.
Any future structured extraction needs spatial/receipt-specific checks and exact
arithmetic reconciliation, with uncertain values left for review. This audit
does not silently insert the missing decimal or replace monetary values.

## What the classifiers received

The receipt projection used by the saved Qwen and Apple runs is 567 UTF-8 bytes,
below the 1,600-byte limit, and was not truncated. It contains all 16 item SKUs,
all 16 correct following item prices, all four discounts and the same three name
typos. Reconstructed complete inputs matched both recorded variants' SHA-256
hashes for both providers. The grocery item list was not lost in transport.

There is a separate context-filter defect: `context_from_text` removes lines
containing four consecutive asterisks, so it drops the legitimate `**** TOTAL`
heading. It was intended to remove irrelevant identifiers/markup, but also loses
this semantic label. The Swift projection uses the same rule. This remains a
known issue; no production extraction or filtering behavior changed in this audit.

These observations weaken the explanation that the shopping predictions came
from missing grocery items. They do not establish why either model selected
shopping, or prove that OCR spelling and formatting had no influence.

## Reproduce

```sh
xcrun swift scripts/inspect_receipt_layout.swift .local/receipts/user-costco/img/costco.jpg .local/receipts/user-costco/ocr-audit/vision-layout.json
.venv/bin/python -m scripts.receipt_ocr_audit --reference experiments/receipts/user-cases/costco-ocr-reference.json --shortcuts-text .local/receipts/user-costco/ocr-audit/shortcuts-ocr.txt --native-jsonl .local/receipts/user-costco/ocr-audit/native-ocr.jsonl --case experiments/receipts/user-cases/costco-groceries.json --layout-json .local/receipts/user-costco/ocr-audit/vision-layout.json --output .local/receipts/user-costco/ocr-audit/audit.json
.venv/bin/python -m pytest -q tests/test_receipt_ocr_audit.py
```

The test suite checks reference reconciliation, known saved OCR defects, a clean
transcription control, missing-price isolation, and table coverage. Passing these
audit tests means the checks behave correctly; it does not mean the OCR's known
footer failures are fixed. The committed
[machine-readable results](../results/2026-10-20-costco-ocr-audit.json) omit raw
private text. Their prior-input hash checks were performed separately against
the ignored original-description file.
