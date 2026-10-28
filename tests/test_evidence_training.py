import copy

import pytest

from scripts.evidence_training import pipeline as p

ANSWER = {"type": "expense", "category": "groceries", "review": True}


def row(identifier="a", split="train", family="market"):
    return {
        "id": identifier,
        "source": "fictional",
        "merchant_family": family,
        "split": split,
        "input": {"description": "Market", "direction": "debit", "currency": "CAD"},
        "answer_with_context": ANSWER.copy(),
        "answer_without_context": ANSWER.copy(),
        "provenance": {"fixture": True},
    }


@pytest.fixture
def frozen(tmp_path, monkeypatch):
    monkeypatch.setattr(p, "PRIVATE", tmp_path)
    labels = tmp_path / "labels.jsonl"
    rows = [row(), row("b", "valid", "second"), row("c", "test", "third")]
    p.write_new(labels, rows, rows=True)
    acceptance = tmp_path / "accepted.json"
    p.write_new(
        acceptance,
        {
            "status": "accepted",
            "labels_sha256": p.sha256(labels),
            "labels_count": 3,
            "policy_version": p.POLICY_VERSION,
            "reviewer": {"model": "gpt-6.1-sol", "reasoning_effort": "high"},
        },
    )
    registry = tmp_path / "historical.jsonl"
    p.write_new(registry, [{"merchant_family": "historical-test", "split": "test"}], rows=True)
    result = p.freeze(labels, acceptance, registry, tmp_path / "frozen")
    return result


def test_freeze_and_verify_do_not_require_prediction_review(frozen):
    manifest, data = p.verify_frozen(frozen)
    assert manifest["labels_count"] == 3
    assert [r["id"] for r in data["train"]] == ["a"]
    assert "test" not in data
    with pytest.raises(FileExistsError):
        p.write_new(frozen / "manifest.json", {})


def test_selection_does_not_open_heldout_payload(frozen):
    (frozen / "test.jsonl").unlink()
    _, data = p.verify_frozen(frozen)
    assert data["valid"][0]["id"] == "b"


def test_frozen_data_tamper_fails(frozen):
    with (frozen / "train.jsonl").open("a") as stream:
        stream.write("\n")
    with pytest.raises(ValueError, match="changed"):
        p.verify_frozen(frozen)


def test_acceptance_binds_bytes_and_count(tmp_path):
    labels = tmp_path / "labels"
    labels.write_text("[]")
    accept = {
        "status": "accepted",
        "labels_sha256": p.sha256(labels),
        "labels_count": 1,
        "policy_version": p.POLICY_VERSION,
        "reviewer": {"model": "gpt-6.1-sol", "reasoning_effort": "high"},
    }
    p.acceptance_check(accept, labels, 1)
    with pytest.raises(ValueError):
        p.acceptance_check(accept, labels, 2)
    labels.write_text("[ ]")
    with pytest.raises(ValueError):
        p.acceptance_check(accept, labels, 1)


def test_registry_rejects_historical_and_current_split_leakage():
    with pytest.raises(ValueError, match="crosses"):
        p.validate_registry(
            [
                {"merchant_family": "same", "split": "train"},
                {"merchant_family": "same", "split": "test"},
            ]
        )
    with pytest.raises(ValueError, match="crosses"):
        p.validate_rows([row()], {"market": "test"})
    with pytest.raises(ValueError, match="crosses"):
        p.validate_rows([row(), row("b", "valid")], {})
    with pytest.raises(ValueError, match="required"):
        p.validate_registry([])


def test_preassigned_splits_and_unique_ids_required():
    bad = row()
    del bad["split"]
    with pytest.raises(ValueError, match="missing"):
        p.validate_rows([bad], {})
    with pytest.raises(ValueError, match="duplicate"):
        p.validate_rows([row(), row()], {})


class Tokenizer:
    def __init__(self, prompt=100, full=120, broken_prefix=False):
        self.prompt, self.full, self.broken_prefix = prompt, full, broken_prefix

    def apply_chat_template(self, messages, **kwargs):
        if messages[-1]["role"] == "assistant":
            return ([1] if self.broken_prefix else [0]) * self.full
        return [0] * self.prompt


def test_token_preflight_rejects_production_cap_and_truncation():
    inputs = row()["input"]
    assert p.token_check(Tokenizer(), inputs, ANSWER, 50) == (100, 120)
    with pytest.raises(ValueError, match="deployed token cap"):
        p.token_check(Tokenizer(513, 530), inputs, ANSWER, 50)
    with pytest.raises(ValueError, match="no truncation"):
        p.token_check(Tokenizer(100, 4000), inputs, ANSWER, 50)
    with pytest.raises(ValueError, match="prefix"):
        p.token_check(Tokenizer(broken_prefix=True), inputs, ANSWER, 50)


def test_prediction_reuses_worker_classify_and_binds_input(tmp_path):
    class FakeWorker:
        identity = {"manifest_sha256": "manifest"}

        def classify(self, request, cancelled):
            assert request["policy_version"] == p.POLICY_VERSION
            assert request["model_manifest_sha256"] == "manifest"
            return {"decision": ANSWER.copy()}

    output = tmp_path / "predictions.jsonl"
    report = p.predict_rows(FakeWorker(), [row()], output, "weights")
    prediction = p.read_rows(output)[0]
    assert prediction["input_sha256"] == p.digest(row()["input"])
    assert prediction["prediction_sha256"] == p.digest(
        {k: v for k, v in prediction.items() if k != "prediction_sha256"}
    )
    assert report["metrics"]["joint_accuracy"] == 1


def replay_artifacts():
    prediction = {
        "id": "a",
        "split": "train",
        "variant": "with_context",
        "input_sha256": p.digest(row()["input"]),
        "model_sha256": "weights",
        "prediction": {"type": "expense", "category": "other", "review": True},
        "error": None,
    }
    prediction["prediction_sha256"] = p.digest(prediction)
    verdict = {
        "id": "a",
        "variant": "with_context",
        "verdict": "label_confirmed_model_wrong",
        "prediction_sha256": prediction["prediction_sha256"],
        "input_sha256": prediction["input_sha256"],
        "model_sha256": "weights",
        "answer_sha256": p.digest(ANSWER),
        "reviewer": {"model": "gpt-6.1-sol", "reasoning_effort": "high"},
    }
    return prediction, verdict


def test_replay_requires_separate_hash_bound_train_verdicts():
    prediction, verdict = replay_artifacts()
    assert len(p.validate_replay([row()], [prediction], [verdict])) == 1
    assert p.validate_replay([row()], [prediction], []) == []
    for field in ("prediction_sha256", "input_sha256", "model_sha256", "answer_sha256"):
        bad = copy.deepcopy(verdict)
        bad[field] = "stale"
        with pytest.raises(ValueError, match="hash-bound"):
            p.validate_replay([row()], [prediction], [bad])
    with pytest.raises(ValueError, match="validation"):
        p.validate_replay([row(split="valid")], [prediction], [verdict])


def test_output_cannot_escape_private_root(tmp_path):
    with pytest.raises(ValueError, match="inside"):
        p.confined(tmp_path.parent / "escape", tmp_path)


def test_no_context_cannot_have_conflicting_targets():
    bad = row()
    bad["answer_without_context"] = {"type": "expense", "category": "other", "review": True}
    with pytest.raises(ValueError, match="paired targets"):
        p.validate_rows([bad], {})


def test_base_requires_original_weight_hash(tmp_path):
    (tmp_path / "model.safetensors").write_bytes(b"not the base")
    with pytest.raises(ValueError, match="approved hash"):
        p.verify_base(tmp_path)
