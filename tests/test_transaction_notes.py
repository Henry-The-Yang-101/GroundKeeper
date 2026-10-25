import json
import pytest
from groundkeeper.policy import validate_input, messages, NOTE_INSTRUCTIONS
from groundkeeper.policy_v2 import messages_v2
from groundkeeper.receipts import context_from_text, laya_receipt_state

BASE = {"description": "Fictional shop", "direction": "debit", "currency": "CAD"}

@pytest.mark.parametrize("builder", [messages, messages_v2])
def test_notes_are_distinct_untrusted_evidence(builder):
    value = {**BASE, "transaction_notes": "Birthday gift for a friend", "receipt_context": context_from_text("BOOK")}
    prompt = builder(value)
    assert NOTE_INSTRUCTIONS in prompt[0]["content"]
    assert json.loads(prompt[1]["content"])["transaction_notes"] == value["transaction_notes"]
    assert laya_receipt_state(value)["transaction_notes"] == value["transaction_notes"]

@pytest.mark.parametrize("note", [None, "", "   ", 1, "x\0y", "☕" * 534])
def test_invalid_notes_rejected(note):
    with pytest.raises(ValueError):
        validate_input({**BASE, "transaction_notes": note})

def test_notes_are_optional_and_bounded_in_bytes():
    assert validate_input(BASE) == BASE
    assert validate_input({**BASE, "transaction_notes": "a" * 1600})["transaction_notes"] == "a" * 1600
