import json

import pytest

from scripts.prepare_evidence_v3 import digest, write_new
from scripts.validate_prediction_review import validate


def fixture(path):
    inputs = {"description": "Fictional Cafe", "direction": "debit", "currency": "CAD"}
    expected = {"type": "expense", "category": "dining", "review": False}
    row = {"id": "fictional", "split": "train", "input": inputs, "input_sha256": digest(inputs)}
    prediction = {"id": "fictional", "split": "train", "variant": "with_context",
                  "input_sha256": digest(inputs), "model_sha256": "fixture-model",
                  "prediction": {**expected, "review": True}, "error": None}
    prediction["prediction_sha256"] = digest(prediction)
    independent = {"id": "fictional", "input_sha256": digest(inputs), "expected": expected,
                   "searches": [{"query": "Fictional Cafe", "status": "no_reliable_match", "urls": []}],
                   "determinacy": "determinate", "rationale": "Explicit cafe cue in this fixture."}
    verdict = {**independent, **{k: prediction[k] for k in ("variant", "model_sha256", "prediction_sha256", "prediction")},
               "verdict": "correct", "reviewer": {"model": "gpt-6.1-sol", "reasoning_effort": "high"}}
    for name, value in [("inputs", row), ("predictions", prediction), ("independent", independent), ("verdicts", verdict)]:
        write_new(path / (name + ".jsonl"), [value])


def test_production_review_flag_is_not_category_error(tmp_path):
    fixture(tmp_path)
    assert validate(tmp_path)["verdicts"] == {"correct": 1}


@pytest.mark.parametrize("mutation", ["model", "prediction", "target", "forced_review_error", "missing_research"])
def test_invalid_verdicts_rejected(tmp_path, mutation):
    fixture(tmp_path)
    path = tmp_path / "verdicts.jsonl"
    row = json.loads(path.read_text())
    if mutation == "model":
        row["model_sha256"] = "wrong"
    elif mutation == "prediction":
        row["prediction"]["category"] = "shopping"
    elif mutation == "target":
        row["expected"]["category"] = "shopping"
    elif mutation == "forced_review_error":
        row["verdict"] = "incorrect"
    else:
        row["searches"] = []
    path.write_text(json.dumps(row))
    with pytest.raises(ValueError):
        validate(tmp_path)
