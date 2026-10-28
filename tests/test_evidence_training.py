import copy
import json

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
    p.write_new(registry, [
        {"merchant_family": "historical-test", "split": "test"},
        {"merchant_family": "protected-alias", "split": "quarantine", "historical_splits": ["train", "test"]},
    ], rows=True)
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


def test_quarantined_registry_cannot_reenter_canonical_data():
    registry = p.validate_registry([{"merchant_family": "market", "split": "quarantine",
                                     "historical_splits": ["train", "test"]}])
    for split in p.SPLITS:
        with pytest.raises(ValueError, match="crosses"):
            p.validate_rows([row(split=split)], registry)
    with pytest.raises(ValueError, match="preassigned"):
        p.validate_rows([row(split="quarantine")], registry)


def test_new_quarantined_alias_requires_explicit_protection_reason():
    base = {"merchant_family": "new-alias", "split": "quarantine", "historical_splits": []}
    with pytest.raises(ValueError, match="historical splits"):
        p.validate_registry([base])
    assert p.validate_registry([{**base, "protected_splits": ["quarantine"], "reason": "Unresolved reviewed alias"}]) == {"new-alias": "quarantine"}


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


def test_selection_lock_is_immutable_and_binds_selected_files(tmp_path, monkeypatch):
    frozen = tmp_path / "frozen"
    frozen.mkdir()
    config = tmp_path / "config.json"
    config.write_text("{}")
    checkpoint = tmp_path / "checkpoint.safetensors"
    checkpoint.write_bytes(b"fixture weights")
    predictions = tmp_path / "predictions.jsonl"
    predictions.write_text("{}\n")
    selection = tmp_path / "selection.json"
    p.write_new(
        selection,
        {
            "selected": {
                "checkpoint": str(checkpoint),
                "checkpoint_sha256": p.sha256(checkpoint),
                "prediction_path": str(predictions),
                "prediction_sha256": p.sha256(predictions),
            },
            "config_sha256": p.sha256(config),
            "test_accessed": False,
        },
    )
    monkeypatch.setattr(p, "load_config", lambda _: ({"frozen": str(frozen)}, {}))
    p.lock(config, selection)
    p.selected_record(config, selection, locked=True)
    with pytest.raises(FileExistsError):
        p.lock(config, selection)
    checkpoint.write_bytes(b"changed")
    with pytest.raises(ValueError, match="changed"):
        p.selected_record(config, selection, locked=True)


def test_holdout_marker_blocks_fitting_and_new_selection(frozen, tmp_path, monkeypatch):
    p.write_new(frozen / "test-access.json", {"purpose": "fixture"})
    with pytest.raises(ValueError, match="further fitting"):
        p.require_unopened(frozen)
    monkeypatch.setattr(p, "load_config", lambda _: ({"frozen": str(frozen)}, {}))
    with pytest.raises(ValueError, match="further fitting"):
        p.train(tmp_path / "config", tmp_path / "qwen", tmp_path / "delaware")


def test_paired_reports_cluster_views_and_surface_source_regressions():
    from scripts.evidence_training.evaluation import paired_report

    rows = [row("a"), row("b", family="second")]
    rows[1]["source"] = "personal"
    gold = []
    for item in rows:
        for variant, inputs, answer in p.variants(item):
            gold.append(
                {
                    "id": item["id"],
                    "variant": variant,
                    "split": "train",
                    "input_sha256": p.digest(inputs),
                    "prediction": answer,
                    "error": None,
                }
            )
    candidate = copy.deepcopy(gold)
    candidate[1]["prediction"] = {"type": "expense", "category": "other", "review": True}
    result = paired_report(rows, candidate, gold, samples=40)
    assert result["cohorts"]["all"]["n_rows"] == 2
    assert result["cohorts"]["all"]["type_category_delta"] == -0.5
    assert result["cohorts"]["source:personal"]["observed_regression"]
    assert result["cohorts"]["source:personal"]["regression_95ci"]
    assert result["cohorts"]["source:fictional"]["type_category_delta_95ci"] == [0, 0]
    bad = copy.deepcopy(candidate)
    bad[0]["input_sha256"] = "different"
    with pytest.raises(ValueError, match="not identical"):
        paired_report(rows, bad, gold, samples=20)


def test_primary_type_category_metric_ignores_forced_review(tmp_path):
    class FakeWorker:
        identity = {"manifest_sha256": "manifest"}

        def classify(self, request, cancelled):
            return {"decision": {**ANSWER, "review": True}}

    fixture = row()
    fixture["answer_with_context"]["review"] = False
    fixture["answer_without_context"]["review"] = False
    report = p.predict_rows(FakeWorker(), [fixture], tmp_path / "predictions", "weights")
    assert report["metrics"]["type_category_accuracy"] == 1
    assert report["metrics"]["joint_accuracy"] == 0
    assert report["metrics"]["production_review_accuracy"] == 0


def test_final_holdout_failure_consumes_access_before_payload_read(frozen, tmp_path, monkeypatch):
    config, selection = tmp_path / "config", tmp_path / "selection.json"
    config.write_text("{}")
    selection.write_text("{}")
    p.write_new(tmp_path / "selection-lock.json", {"fixture": True})
    monkeypatch.setattr(p, "RUN", tmp_path)
    monkeypatch.setattr(
        p,
        "selected_record",
        lambda *a, **k: ({"frozen": str(frozen)}, {"selected": {"checkpoint_sha256": "selected"}}),
    )
    monkeypatch.setattr(
        p,
        "verify_package",
        lambda *a, **k: (
            {"files": {"adapters/adapters.safetensors": {"sha256": "selected"}}},
            "package",
        ),
    )
    (frozen / "test.jsonl").write_text("corrupt sealed payload")
    with pytest.raises(ValueError, match="Sealed held-out payload changed"):
        p.final_score(
            config,
            selection,
            tmp_path / "package",
            tmp_path / "old",
            tmp_path / "delaware",
            output=tmp_path / "report.json",
        )
    marker = json.loads((frozen / "test-access.json").read_text())
    assert marker["failure_also_consumes_holdout"]
    assert marker["further_fitting_forbidden"]
    with pytest.raises(ValueError, match="further fitting"):
        p.require_unopened(frozen)


@pytest.mark.parametrize("baseline_timing", ["before", "after"])
def test_reviewed_cycle_resumes_only_parent_weights_with_fresh_optimizer(tmp_path, monkeypatch, baseline_timing):
    from contextlib import nullcontext
    from scripts.evidence_training import recurrent_checkpoint
    monkeypatch.setattr(recurrent_checkpoint, "recurrent_checkpoints", lambda *a: nullcontext())
    import sys
    from types import ModuleType, SimpleNamespace

    monkeypatch.setattr(p, "PRIVATE", tmp_path / "private")
    monkeypatch.setattr(p, "RUN", tmp_path / "runs")
    frozen = tmp_path / "private/frozen"
    frozen.mkdir(parents=True)
    config = tmp_path / "runs/config.json"
    config.parent.mkdir()
    config.write_text("{}")
    parent = tmp_path / "parent/adapters.safetensors"
    parent.parent.mkdir()
    parent.write_bytes(b"parent weights")
    p.write_new(
        parent.parent / "adapter_config.json", {"num_layers": 4, "lora_parameters": {"rank": 8}}
    )
    prediction, verdict = replay_artifacts()
    prediction["model_sha256"] = p.sha256(parent)
    prediction["prediction_sha256"] = p.digest(
        {k: v for k, v in prediction.items() if k != "prediction_sha256"}
    )
    verdict.update(model_sha256=p.sha256(parent), prediction_sha256=prediction["prediction_sha256"])
    pred_path, verdict_path = tmp_path / "predictions", tmp_path / "verdicts"
    p.write_new(pred_path, [prediction], rows=True)
    p.write_new(verdict_path, [verdict], rows=True)
    selection = tmp_path / "parent/selection.json"
    selection.write_text("{}")
    cfg = {
        "frozen": str(frozen),
        "model": "fixture-base",
        "seed": 1,
        "learning_rate": 1e-5,
        "batch_size": 1,
        "grad_accumulation_steps": 8,
        "num_layers": 4,
        "lora_parameters": {"rank": 8},
        "iters": 8,
        "checkpoint_steps": [8],
        "expanded_counts": {"train": 1},
        "answer_room": 17,
        "max_seq_length": 3089,
    }
    monkeypatch.setattr(
        p, "load_config", lambda _: (cfg, {"train": [row()], "valid": [row("b", "valid", "other")]})
    )
    monkeypatch.setattr(
        p,
        "selected_record",
        lambda *a, **k: (
            cfg,
            {
                "selected": {
                    "checkpoint": str(parent),
                    "checkpoint_sha256": p.sha256(parent),
                    "metrics": {
                        "production": {
                            "macro_f1_supported_categories": 0.5,
                            "type_category_accuracy": 0.5,
                        }
                    },
                    "invalid_outputs": 0,
                    "step": 8,
                }
            },
        ),
    )
    events = []
    def baseline(*args, **kwargs):
        events.append("baseline")
        return {"fixture_baseline": True}
    monkeypatch.setattr(p, "predict", baseline)

    class Model:
        def trainable_parameters(self):
            return {"weight": 1}

        def eval(self):
            pass

        def train(self):
            pass

    class Dataset:
        def __init__(self, messages, tokenizer, mask_prompt):
            assert mask_prompt
            self._data = messages

        def process(self, item):
            return [0] * 120, 100

    modules = {
        name: ModuleType(name)
        for name in (
            "mlx",
            "mlx.core",
            "mlx.utils",
            "mlx_lm",
            "mlx_lm.lora",
            "mlx_lm.tuner",
            "mlx_lm.tuner.callbacks",
            "mlx_lm.tuner.datasets",
        )
    }
    mx = modules["mlx.core"]
    mx.set_memory_limit = mx.set_cache_limit = lambda _: None
    mx.clear_cache = lambda: None
    mx.random = SimpleNamespace(seed=lambda _: None)
    mx.save_safetensors = lambda path, weights: (
        __import__("pathlib").Path(path).write_bytes(b"new checkpoint")
    )
    mx.load = lambda _: {"weight": 1}
    mx.array_equal = lambda a, b: SimpleNamespace(item=lambda: a == b)
    modules["mlx"].core = mx
    modules["mlx.utils"].tree_flatten = lambda value: list(value.items())
    modules["mlx_lm"].load = lambda *a, **k: (Model(), Tokenizer())
    modules["mlx_lm.tuner.callbacks"].TrainingCallback = object
    modules["mlx_lm.tuner.datasets"].ChatDataset = Dataset
    modules["mlx_lm.lora"].CONFIG_DEFAULTS = {}
    seen = {}

    def fake_train(args, model, training, validation, callback):
        events.append("fit")
        seen.update(vars(args))
        seen["train_n"], seen["valid_n"] = len(training._data), len(validation._data)
        __import__("pathlib").Path(args.adapter_path).mkdir()
        callback.on_val_loss_report({"iteration": 0})
        callback.on_train_loss_report({"iteration": 8})

    modules["mlx_lm.lora"].train_model = fake_train
    for name, module in modules.items():
        monkeypatch.setitem(sys.modules, name, module)
    monkeypatch.setattr(p, "worker_for_model", lambda *a: None)

    def fake_predictions(worker, rows, output, model_sha256):
        p.write_new(output, [], rows=True)
        return {
            "metrics": {
                "production": {"macro_f1_supported_categories": 1, "type_category_accuracy": 1}
            },
            "prediction_path": str(output),
            "prediction_sha256": p.sha256(output),
            "invalid_outputs": 0,
        }

    monkeypatch.setattr(p, "predict_rows", fake_predictions)
    result = p.cycle(
        config, "old-qwen", "old-delaware", "reviewed-1", selection, pred_path, verdict_path,
        baseline_timing=baseline_timing,
    )
    assert result["step"] == 8
    assert seen["resume_adapter_file"] == str(parent)
    assert seen["optimizer"] == "adam" and seen["optimizer_config"] == {}
    assert seen["train_n"] == 2 and seen["valid_n"] == 1
    cycle_cfg = json.loads((config.parent / "cycles/reviewed-1/cycle-config.json").read_text())
    assert cycle_cfg["optimizer_resumed"] is False
    assert cycle_cfg["parent_checkpoint_sha256"] == p.sha256(parent)
    assert cycle_cfg["replay_n"] == 1
    assert cycle_cfg["baseline_timing"] == baseline_timing
    assert events == (["fit"] + ["baseline"] * 4 if baseline_timing == "after" else ["baseline"] * 4 + ["fit"])


def test_deployment_input_mode_keeps_real_context_and_honest_fallback():
    item = row()
    item["input"]["merchant_context"] = {
        "version": "merchant-search-v1", "source": "duckduckgo",
        "results": [{"title": "Fictional business", "body": "Actual frozen fixture snippet", "url": "https://fixture.example/"}],
    }
    original = copy.deepcopy(item)
    deployed = list(p.variants(item, include_without_context=False))
    assert deployed == [("with_context", original["input"], original["answer_with_context"])]
    assert item == original
    assert len(list(p.variants(item))) == 2
    fallback = row("no-result")
    assert list(p.variants(fallback, include_without_context=False))[0][1] == fallback["input"]


def test_forced_review_difference_is_not_a_category_replay_mistake():
    fixture = row()
    fixture["answer_with_context"]["review"] = False
    fixture["answer_without_context"]["review"] = False
    prediction, verdict = replay_artifacts()
    prediction["prediction"] = {**fixture["answer_with_context"], "review": True}
    prediction["prediction_sha256"] = p.digest(
        {k: v for k, v in prediction.items() if k != "prediction_sha256"}
    )
    verdict["prediction_sha256"] = prediction["prediction_sha256"]
    verdict["answer_sha256"] = p.digest(fixture["answer_with_context"])
    with pytest.raises(ValueError, match="TRAIN mistake"):
        p.validate_replay([fixture], [prediction], [verdict])


def test_paired_bootstrap_keeps_repeated_family_rows_together():
    from scripts.evidence_training.evaluation import paired_report

    rows = [row("a", family="same-family"), row("b", family="same-family")]
    predictions = []
    for fixture in rows:
        predictions.append(
            {
                "id": fixture["id"],
                "variant": "with_context",
                "split": "train",
                "input_sha256": p.digest(fixture["input"]),
                "prediction": ANSWER.copy(),
                "error": None,
            }
        )
    candidate = copy.deepcopy(predictions)
    candidate[0]["prediction"]["category"] = "other"
    report = paired_report(rows, candidate, predictions, samples=30)
    cohort = report["cohorts"]["variant:with_context"]
    assert cohort["n_rows"] == 2 and cohort["n_families"] == 1
    assert cohort["type_category_delta_95ci"] == [-0.5, -0.5]
    assert report["primary_cohort"] == "variant:with_context"
    assert "source:fictional/variant:with_context" in report["cohorts"]
    assert cohort["per_category"]["groceries"]["support"] == 2
    assert cohort["candidate_specific_suggestion_coverage"] == 0.5
