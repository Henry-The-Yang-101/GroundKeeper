import json
from pathlib import Path

from scripts.receipt_ocr_audit import audit, audit_layout

ROOT = Path(__file__).resolve().parents[1] / "experiments/receipts/user-cases"


def test_costco_reference_reconciles_and_audit_exposes_saved_ocr_defects():
    reference = json.loads((ROOT / "costco-ocr-reference.json").read_text())
    case = json.loads((ROOT / "costco-groceries.json").read_text())
    assert (
        sum(i["price_cents"] for i in reference["items"])
        + sum(d["amount_cents"] for d in reference["discounts"])
        == reference["footer_cents"]["SUBTOTAL"]
    )
    assert (
        reference["footer_cents"]["SUBTOTAL"] + reference["footer_cents"]["TAX"]
        == reference["footer_cents"]["TOTAL"]
    )
    result = audit(case["receipt_ocr"]["text"], reference)
    assert result["sku_matches"] == result["next_price_matches"] == 16
    assert result["discount_matches"] == 4
    assert result["exact_name_matches"] == 13
    assert not result["footer"]["TOTAL"]["expected_decimal_literal_present"]
    assert not any(r["adjacent_pair_matches"] for r in result["footer"].values())


def test_missing_price_cannot_be_taken_from_the_next_item():
    ref = {
        "items": [
            {"sku": "1234", "name": "BREAD", "price_cents": 399},
            {"sku": "5678", "name": "MILK", "price_cents": 399},
        ],
        "discounts": [],
        "footer_cents": {},
    }
    result = audit("1234 BREAD\n5678 MILK\n3.99", ref)
    assert result["items"][0]["observed_next_price_cents"] is None
    assert result["next_price_matches"] == 1


def test_correct_transcription_passes_item_discount_and_footer_checks():
    ref = json.loads((ROOT / "costco-ocr-reference.json").read_text())

    def money(value):
        return f"{abs(value) // 100}.{abs(value) % 100:02d}"

    text = "\n".join(f"{i['sku']} {i['name']}\n{money(i['price_cents'])}" for i in ref["items"])
    text += "\n" + "\n".join(
        f"COUPON /{d['sku']}\n{money(d['amount_cents'])}-" for d in ref["discounts"]
    )
    text += "\n" + "\n".join(
        f"{label}\n{money(value)}" for label, value in ref["footer_cents"].items()
    )
    result = audit(text, ref)
    assert (
        result["sku_matches"] == result["exact_name_matches"] == result["next_price_matches"] == 16
    )
    assert result["discount_matches"] == 4
    assert all(r["adjacent_pair_matches"] for r in result["footer"].values())


def test_table_audit_does_not_claim_coverage_for_items_outside_tables():
    ref = {
        "items": [{"sku": "1234", "price_cents": 399}, {"sku": "5678", "price_cents": 399}],
        "footer_cents": {"TOTAL": 399},
    }
    result = audit_layout(
        {
            "tables": [
                {
                    "rows": [
                        [{"text": "1234 BREAD"}, {"text": "3.99"}],
                        [{"text": "TOTAL"}, {"text": "399"}],
                    ]
                }
            ]
        },
        ref,
    )
    assert result["item_skus_in_tables"] == result["same_row_price_matches"] == 1
    assert result["footer_rows"] == [["TOTAL", "399"]]
