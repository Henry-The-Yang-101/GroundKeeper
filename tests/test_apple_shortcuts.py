import json
import subprocess
from pathlib import Path

import pytest

from groundkeeper.apple_shortcuts import ShortcutExecutionError, run_shortcut
from scripts.benchmark_apple_shortcuts import summarize


INPUT = {"description": "TIM HORTONS", "direction": "debit", "currency": "CAD"}
ANSWER = {"type": "expense", "category": "dining", "review": False}


def test_shortcut_sends_only_input_and_validates_return(monkeypatch):
    def execute(command, **kwargs):
        request = Path(command[command.index("--input-path")+1])
        assert json.loads(request.read_text()) == INPUT
        output = Path(command[command.index("--output-path")+1])
        output.write_text(json.dumps(ANSWER))
        return subprocess.CompletedProcess(command, 0, "", "")
    monkeypatch.setattr(subprocess, "run", execute)
    prediction, detail = run_shortcut(INPUT)
    assert prediction == ANSWER and detail["valid_schema"]


def test_quota_error_is_preserved_without_fabricating_prediction(monkeypatch):
    monkeypatch.setattr(subprocess, "run", lambda command, **kwargs:
        subprocess.CompletedProcess(command, 1, "", "Too many incoming requests"))
    with pytest.raises(ShortcutExecutionError, match="Too many") as error:
        run_shortcut(INPUT)
    assert error.value.detail["status"] == "execution_error"
    assert not error.value.detail["valid_schema"]


def test_invalid_output_receives_no_accuracy_credit():
    abstention = {"type": "unknown", "category": "uncategorized", "review": True}
    rows = [{"id": "a", "answer": ANSWER, "input": INPUT, "source": "synthetic"},
            {"id": "b", "answer": abstention, "input": INPUT, "source": "synthetic"}]
    records = [{"id": "a", "status": "ok", "prediction": ANSWER,
                "valid_schema": True, "latency_seconds": 1},
               {"id": "b", "status": "invalid_output", "raw": "not JSON",
                "valid_schema": False, "latency_seconds": 1}]
    report = summarize(rows, records, {"a": ANSWER, "b": abstention})
    assert report["all_completed_accuracy"]["category_accuracy"] == .5
    assert report["all_completed_accuracy"]["joint_accuracy"] == .5
    assert report["valid_output_metrics"]["category_accuracy"] == 1
    assert report["invalid_outputs"] == 1
