import pytest

from groundkeeper.metrics import evaluate
from groundkeeper.policy import messages, safe_prediction, validate_answer, validate_input
from scripts.prepare_training import canonical_group


def test_strict_schema_and_no_generated_confidence():
    with pytest.raises(ValueError):
        validate_answer(
            {"type": "expense", "category": "dining", "review": False, "confidence": 0.9}
        )
    with pytest.raises(ValueError):
        validate_answer({"type": "unknown", "category": None, "review": True})
    with pytest.raises(ValueError):
        validate_answer({"type": "income", "category": "shopping", "review": False})
    assert safe_prediction("not JSON") == {"type": "unknown", "category": "other", "review": True}


def test_no_hidden_label_features():
    with pytest.raises(ValueError):
        validate_input(
            {
                "description": "Amazon",
                "direction": "debit",
                "currency": "CAD",
                "source_category": "Gifts",
            }
        )
    assert len(messages({"description": "Amazon", "direction": "debit", "currency": "CAD"})) == 2


def test_parent_chains_and_generic_payment_templates():
    inp = {"description": "AMAZON", "direction": "debit", "currency": "CAD"}
    assert canonical_group({"merchant_group": "Whole Foods Market"}, inp) == canonical_group(
        {"merchant_group": "Amazon"}, inp
    )
    a = {"description": "Zelle payment from Bob", "direction": "credit", "currency": "USD"}
    assert canonical_group({"merchant_group": "generic:zelle_receipt"}, a) == "generic:p2p"


def test_zero_acceptance_error_rate_is_unavailable_not_perfect():
    gold = [{"type": "expense", "category": "dining", "review": False}]
    pred = [{"type": "expense", "category": "shopping", "review": False}]
    r = evaluate(gold, pred)
    assert (
        r["automatic_acceptance_coverage"] == 0 and r["automatically_accepted_error_rate"] is None
    )
    assert evaluate(gold, pred, [True])["automatically_accepted_error_rate"] == 1


def test_only_a_whole_json_fence_is_repaired():
    from groundkeeper.policy import parse_answer

    assert (
        parse_answer('```json\n{"type":"expense","category":"dining","review":false}\n```')[
            "category"
        ]
        == "dining"
    )
    with pytest.raises(ValueError):
        parse_answer('Here is JSON: {"type":"expense","category":"dining","review":false}')
    with pytest.raises(ValueError):
        parse_answer('```json\n{"type":"income","category":"dining","review":false}\n```')
