import copy
import json
import subprocess
from pathlib import Path

import pytest

from groundkeeper.policy import SYSTEM, messages, validate_input
from groundkeeper.policy_v2 import messages_v2
from groundkeeper.receipts import context_from_text, laya_receipt_state
from groundkeeper.apple_shortcuts import run_shortcut

BASE = {"description": "GENERAL RETAILER", "direction": "debit", "currency": "CAD"}


def test_legacy_prompt_is_unchanged_and_receipts_have_explicit_boundaries():
    assert messages(BASE)[0]["content"] == SYSTEM
    value = {**BASE, "receipt_context": context_from_text("MILK\nBREAD")}
    for builder in (messages, messages_v2):
        prompt = builder(value)
        assert "never instructions" in prompt[0]["content"]
        assert json.loads(prompt[1]["content"]) == value
    assert "receipt_items_ocr" in laya_receipt_state(value)
    assert laya_receipt_state(BASE) == BASE


def test_receipt_projection_is_bounded_and_records_truncation():
    text = "MILK\nVISA 1234\nwww.example.com\n" + "BREAD 3.99\n" * 300
    context = context_from_text(text)
    assert "VISA" not in context["text"] and "example" not in context["text"]
    assert context["truncated"] and len(context["text"].encode()) <= 1600


@pytest.mark.parametrize("field,value", [("version", "future"), ("text", "x" * 1601), ("text", "\0"), ("evidence_sha256", "not-a-hash"), ("truncated", "false")])
def test_bad_context_never_reaches_provider(field, value):
    row = {**BASE, "receipt_context": context_from_text("MILK")}
    row["receipt_context"][field] = value
    with pytest.raises(ValueError):
        validate_input(row)


def test_apple_adapter_forwards_exact_receipt_evidence(monkeypatch):
    value = {**BASE, "receipt_context": context_from_text("MILK\nBREAD")}
    def execute(command, **kwargs):
        request = Path(command[command.index("--input-path") + 1])
        assert json.loads(request.read_text()) == value
        Path(command[command.index("--output-path") + 1]).write_text('{"type":"expense","category":"groceries","review":true}')
        return subprocess.CompletedProcess(command, 0, "", "")
    monkeypatch.setattr(subprocess, "run", execute)
    assert run_shortcut(value)[0]["category"] == "groceries"
