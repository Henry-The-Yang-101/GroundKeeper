"""Scoring integrity checks only; these fixtures are never model benchmark data."""
import json

import pytest

from scripts.benchmark_real_merchant_search import digest, frozen, metrics, paired


def prediction(identifier, category, context=False):
    return {"id": identifier, "decision": {"type": "expense", "category": category, "review": True},
            "seconds": 1.0, "web_context_used": context}


def test_paired_scoring_keeps_failures_and_distinguishes_regressions():
    reference = [{"id": str(i), "answer": {"type": "expense", "category": category, "review": True}}
                 for i, category in enumerate(("dining", "travel", "shopping", "groceries"))]
    baseline = [prediction(str(i), category) for i, category in enumerate(("dining", "travel", "uncategorized", "uncategorized"))]
    enriched = [prediction(str(i), category, i < 3) for i, category in enumerate(("dining", "uncategorized", "shopping", "uncategorized"))]
    result = metrics(reference, enriched)
    assert result["n"] == 4 and result["context_rows"] == 3
    assert result["category_agreement"] == 2
    assert paired(reference, baseline, enriched) == {"n": 4, "both_agree": 1,
        "baseline_only_agrees": 1, "enriched_only_agrees": 1, "neither_agrees": 1,
        "category_changed": 2, "uncovered_decision_changes": 0}
    with pytest.raises(ValueError, match="order or IDs"):
        metrics(reference, list(reversed(enriched)))
    with pytest.raises(ValueError, match="aligned"):
        metrics(reference, enriched[:-1])


def test_frozen_inputs_cannot_silently_change(tmp_path):
    sample = tmp_path / "sample.jsonl"
    reference = tmp_path / "reference.jsonl"
    sample.write_text(json.dumps({"id": "one", "input": {"description": "fixture"}}) + "\n")
    reference.write_text(json.dumps({"id": "one", "answer": {}}) + "\n")
    manifest = {"reference_status": "frozen_before_model_inference", "training_allowed": False,
                "sample_sha256": digest(sample), "reference_sha256": digest(reference)}
    (tmp_path / "manifest.json").write_text(json.dumps(manifest))
    assert len(frozen(tmp_path)[1]) == 1
    sample.write_text(sample.read_text().replace("fixture", "edited"))
    with pytest.raises(ValueError, match="changed"):
        frozen(tmp_path)
