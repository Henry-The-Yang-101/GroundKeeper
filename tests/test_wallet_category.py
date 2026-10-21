import json
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from groundkeeper.apple_shortcuts import run_shortcut
from groundkeeper.laya_runtime import LocalLayaCategorizer
from groundkeeper.policy import SYSTEM, WALLET_CATEGORY_INSTRUCTIONS, messages, validate_input
from groundkeeper.policy_v2 import SYSTEM_V2, messages_v2
from groundkeeper.receipts import context_from_text, laya_receipt_state

BASE = {"description": "FICTIONAL CAFE", "direction": "debit", "currency": "CAD"}


@pytest.mark.parametrize("receipt", [False, True])
def test_hint_and_receipt_reach_both_prompts_and_laya(receipt):
    inputs = {**BASE, "wallet_category_raw": "Food & Drink"}
    if receipt:
        inputs["receipt_context"] = context_from_text("MILK\nBREAD")
    for builder in (messages, messages_v2):
        prompt = builder(inputs)
        assert WALLET_CATEGORY_INSTRUCTIONS in prompt[0]["content"]
        assert json.loads(prompt[1]["content"]) == inputs
    assert laya_receipt_state(inputs)["wallet_category_raw"] == "Food & Drink"
    observed = {}
    def predict(state, questions, **kwargs):
        observed.update(state=state, questions=questions, **kwargs)
        return {"answers": {}}  # Invalid model output must still fall back to review.
    model = LocalLayaCategorizer.__new__(LocalLayaCategorizer)
    model.agent = SimpleNamespace(predict=predict)
    answer, _ = model.predict(inputs)
    assert answer["review"]
    assert observed["state"]["wallet_category_raw"] == "Food & Drink"
    assert all(WALLET_CATEGORY_INSTRUCTIONS in q["instructions"] for q in observed["questions"].values())
    assert observed["max_len"] == 1024


def test_absent_hint_keeps_legacy_prompts_unchanged():
    assert messages(BASE)[0]["content"] == SYSTEM
    assert messages_v2(BASE)[0]["content"] == SYSTEM_V2
    assert laya_receipt_state(BASE) == BASE


@pytest.mark.parametrize("hint", [None, 5, {}, "", "   ", "a" * 129, "界" * 43, "Food\nDrink", "Food\0", "Food\x7f"])
def test_invalid_hint_is_rejected_at_worker_boundary(hint):
    with pytest.raises(ValueError, match="Wallet category"):
        validate_input({**BASE, "wallet_category_raw": hint})


def test_apple_adapter_forwards_hint_as_data(monkeypatch):
    inputs = {**BASE, "wallet_category_raw": "Food & Drink", "receipt_context": context_from_text("MILK")}
    def execute(command, **kwargs):
        assert json.loads(Path(command[command.index("--input-path") + 1]).read_text()) == inputs
        Path(command[command.index("--output-path") + 1]).write_text('{"type":"expense","category":"groceries","review":true}')
        return subprocess.CompletedProcess(command, 0, "", "")
    monkeypatch.setattr(subprocess, "run", execute)
    assert run_shortcut(inputs)[0]["category"] == "groceries"
