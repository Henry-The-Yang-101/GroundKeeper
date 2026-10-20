import copy
import json
from pathlib import Path

from groundkeeper.policy import validate_input
from scripts.receipt_case import variants


def test_user_costco_case_preserves_label_and_only_adds_receipt_evidence():
    case = json.loads((Path(__file__).resolve().parents[1] / "experiments/receipts/user-cases/costco-groceries.json").read_text())
    assert case["expected"] == {"type": "expense", "category": "groceries"}
    assert case["provenance"]["receipt_transaction_amount_match"] is False
    baseline, enriched = [value for _, value in variants(case)]
    validate_input(baseline)
    validate_input(enriched)
    assert {k: v for k, v in enriched.items() if k != "receipt_context"} == baseline
    assert "GRANOLA" in enriched["receipt_context"]["text"]
    assert "GRAPES" in enriched["receipt_context"]["text"]
    assert "member" not in case["receipt_ocr"]["text"].lower()
    different_gold = copy.deepcopy(case)
    different_gold["expected"] = {"type": "unknown", "category": "uncategorized"}
    assert variants(different_gold) == variants(case), "Gold labels must never enter model inputs"
