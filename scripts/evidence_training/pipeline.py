"""Run with python -m scripts.evidence_training; never promotes a model.

All private rows and predictions stay in .private; adapters stay in .local.
The initial label acceptance gate deliberately does not require predictions.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import os
import shutil
from pathlib import Path
from types import SimpleNamespace

from groundkeeper.policy import validate_answer, validate_input
from groundkeeper.policy_v2 import messages_v2
from groundkeeper.worker import POLICY_VERSION, Worker, input_token_limit, verify_package
from scripts.common_io import read_rows, sha256

BASE = Path(".local/finetune/models/qwen35-text")
BASE_SHA256 = "d58b87def677c7b3235e21cdca85289a162a5ba8949687b9573592e3c74cd477"
PRIVATE = Path(".private/qwen-evidence-v3")
RUN = Path(".local/finetune/evidence-v3")
SPLITS = ("train", "valid", "test")
CORE_FIELDS = {
    "id",
    "source",
    "merchant_family",
    "split",
    "input",
    "answer_with_context",
    "answer_without_context",
    "provenance",
}


def digest(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    ).hexdigest()


def write_new(path, value, *, rows=False):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x") as stream:
        if rows:
            for row in value:
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")
        else:
            stream.write(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def confined(path, root):
    path, root = Path(path).resolve(), Path(root).resolve()
    if not path.is_relative_to(root):
        raise ValueError(f"Output must stay inside {root}")
    return path


def validate_registry(rows):
    registry = {}
    for row in rows:
        family, split = row["merchant_family"], row["split"]
        if not isinstance(family, str) or not family.strip() or split not in (*SPLITS, "quarantine"):
            raise ValueError("Invalid historical family registry")
        if split == "quarantine":
            history = row.get("historical_splits")
            if (not isinstance(history, list)
                    or any(value not in SPLITS for value in history)
                    or (not history and (row.get("protected_splits") != ["quarantine"]
                                         or not row.get("reason")))):
                raise ValueError("Quarantined registry families require actual historical splits")
        if family in registry and registry[family] != split:
            raise ValueError("Historical merchant family crosses splits")
        registry[family] = split
    if not registry:
        raise ValueError("Full historical merchant family registry is required")
    return registry


def validate_rows(rows, registry):
    seen, families = set(), dict(registry)
    for row in rows:
        if not CORE_FIELDS <= row.keys():
            raise ValueError("Canonical row missing required fields")
        if not isinstance(row["id"], str) or not row["id"] or row["id"] in seen:
            raise ValueError("Missing or duplicate canonical ID")
        seen.add(row["id"])
        family, split = row["merchant_family"], row["split"]
        if not isinstance(family, str) or not family.strip() or split not in SPLITS:
            raise ValueError("Every row requires a preassigned split and family")
        if family in families and families[family] != split:
            raise ValueError("Merchant family crosses historical or current splits")
        families[family] = split
        if (
            not isinstance(row["source"], str)
            or not row["source"]
            or not isinstance(row["provenance"], dict)
            or not row["provenance"]
        ):
            raise ValueError("Source and nonempty provenance are required")
        validate_input(row["input"])
        validate_answer(row["answer_with_context"])
        validate_answer(row["answer_without_context"])
        if len(row["input"]["description"]) > 2048:
            raise ValueError("Description exceeds production limit")
        if (
            "merchant_context" not in row["input"]
            and row["answer_with_context"] != row["answer_without_context"]
        ):
            raise ValueError("No web context but paired targets disagree")
    if not rows:
        raise ValueError("No canonical rows")
    return families


def acceptance_check(acceptance, labels_path, count):
    reviewer = acceptance.get("reviewer", {})
    if (
        acceptance.get("status") != "accepted"
        or acceptance.get("labels_sha256") != sha256(labels_path)
        or acceptance.get("labels_count") != count
        or acceptance.get("policy_version") != POLICY_VERSION
        or reviewer.get("model") != "gpt-6.1-sol"
        or reviewer.get("reasoning_effort") != "high"
    ):
        raise ValueError(
            "Reviewed-label acceptance must bind exact label bytes/count and current policy"
        )


def freeze(labels, acceptance, family_registry, destination=PRIVATE / "frozen"):
    destination = confined(destination, PRIVATE)
    if destination.exists():
        raise FileExistsError(destination)
    rows = read_rows(labels)
    accept = json.loads(Path(acceptance).read_text())
    acceptance_check(accept, labels, len(rows))
    registry = validate_registry(read_rows(family_registry))
    families = validate_rows(rows, registry)
    if any(not any(r["split"] == split for r in rows) for split in SPLITS):
        raise ValueError("Frozen corpus must contain train, valid, and sealed test")
    destination.mkdir(parents=True)
    for split in SPLITS:
        write_new(
            destination / f"{split}.jsonl", [r for r in rows if r["split"] == split], rows=True
        )
    shutil.copy2(acceptance, destination / "acceptance.json")
    shutil.copy2(family_registry, destination / "historical-family-registry.jsonl")
    write_new(
        destination / "split-manifest.jsonl",
        [
            {
                "id": r["id"],
                "source": r["source"],
                "merchant_family": r["merchant_family"],
                "split": r["split"],
            }
            for r in rows
        ],
        rows=True,
    )
    write_new(
        destination / "manifest.json",
        {
            "policy_version": POLICY_VERSION,
            "labels_sha256": sha256(labels),
            "labels_count": len(rows),
            "acceptance_sha256": sha256(destination / "acceptance.json"),
            "historical_registry_sha256": sha256(destination / "historical-family-registry.jsonl"),
            "split_manifest_sha256": sha256(destination / "split-manifest.jsonl"),
            "split_counts": {s: sum(r["split"] == s for r in rows) for s in SPLITS},
            "split_hashes": {s: sha256(destination / f"{s}.jsonl") for s in SPLITS},
            "family_registry_count": len(registry),
            "combined_family_count": len(families),
        },
    )
    return destination


def variants(row):
    yield "with_context", row["input"], row["answer_with_context"]
    if "merchant_context" in row["input"]:
        yield (
            "without_context",
            {k: v for k, v in row["input"].items() if k != "merchant_context"},
            row["answer_without_context"],
        )


def verify_frozen(frozen):
    frozen = confined(frozen, PRIVATE)
    manifest = json.loads((frozen / "manifest.json").read_text())
    if manifest["policy_version"] != POLICY_VERSION:
        raise ValueError("Frozen policy is stale")
    for name, field in [
        ("acceptance.json", "acceptance_sha256"),
        ("historical-family-registry.jsonl", "historical_registry_sha256"),
        ("split-manifest.jsonl", "split_manifest_sha256"),
    ]:
        if sha256(frozen / name) != manifest[field]:
            raise ValueError("Frozen acceptance or split registry changed")
    accept = json.loads((frozen / "acceptance.json").read_text())
    if (
        accept["labels_sha256"] != manifest["labels_sha256"]
        or accept["labels_count"] != manifest["labels_count"]
        or accept["status"] != "accepted"
    ):
        raise ValueError("Acceptance binding changed")
    registry_rows = read_rows(frozen / "historical-family-registry.jsonl")
    registry = validate_registry(registry_rows)
    split_rows = read_rows(frozen / "split-manifest.jsonl")
    validate_registry(
        [*registry_rows, *split_rows]
    )
    data = {}
    # Test payload is never read during preparation, selection, or packaging.
    for split in ("train", "valid"):
        if sha256(frozen / f"{split}.jsonl") != manifest["split_hashes"][split]:
            raise ValueError("Frozen training/validation data changed")
        data[split] = read_rows(frozen / f"{split}.jsonl")
        validate_rows(data[split], registry)
        expected = {r["id"] for r in split_rows if r["split"] == split}
        if (
            len(data[split]) != manifest["split_counts"][split]
            or {r["id"] for r in data[split]} != expected
            or any(r["split"] != split for r in data[split])
        ):
            raise ValueError("Frozen split membership mismatch")
    return manifest, data


def code_hashes():
    paths = [*Path(__file__).parent.glob("*.py"), *Path("groundkeeper").glob("*.py")]
    return {str(p): sha256(p) for p in paths}


def runtime_versions():
    return {
        name: importlib.metadata.version(name)
        for name in ("mlx", "mlx-lm", "numpy", "transformers")
    }


def verify_base(base=BASE):
    if sha256(Path(base) / "model.safetensors") != BASE_SHA256:
        raise ValueError("Fresh original Qwen base does not match approved hash")
    if any(Path(base).glob("*adapter*")):
        raise ValueError("Base directory unexpectedly contains adapter files")


def token_check(tokenizer, inputs, answer, answer_room):
    prompt = tokenizer.apply_chat_template(
        messages_v2(inputs),
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=False,
        return_dict=False,
    )
    full = tokenizer.apply_chat_template(
        messages_v2(inputs, answer),
        tokenize=True,
        add_generation_prompt=False,
        enable_thinking=False,
        return_dict=False,
    )
    if not (0 < len(prompt) < len(full) and full[: len(prompt)] == prompt):
        raise ValueError("Assistant-only training prefix mismatch")
    if len(prompt) > min(3072, input_token_limit(inputs)):
        raise ValueError("Input exceeds deployed token cap; repair context before freezing")
    if len(full) > 3072 + answer_room:
        raise ValueError("Sequence exceeds input plus answer room; no truncation allowed")
    return len(prompt), len(full)


def preflight(frozen=PRIVATE / "frozen", config=RUN / "config.json", base=BASE):
    config = confined(config, RUN)
    if config.exists():
        raise FileExistsError(config)
    manifest, data = verify_frozen(frozen)
    require_unopened(frozen)
    verify_base(base)
    from mlx_lm.utils import load_tokenizer

    from groundkeeper.constraints import DecisionGrammar

    tokenizer = load_tokenizer(Path(base), tokenizer_config_extra={"trust_remote_code": False})
    answer_room = DecisionGrammar(tokenizer).max_answer_tokens + 2
    lengths, counts = [], {}
    for split, rows in data.items():
        count = 0
        for row in rows:
            for _, inputs, answer in variants(row):
                lengths.append(token_check(tokenizer, inputs, answer, answer_room))
                count += 1
        counts[split] = count
    iters = math.ceil(counts["train"] / 8) * 8
    checkpoints = sorted(
        {min(iters, max(8, math.ceil(iters * fraction / 3 / 8) * 8)) for fraction in (1, 2, 3)}
    )
    value = {
        "policy_version": POLICY_VERSION,
        "frozen": str(Path(frozen).resolve()),
        "manifest_sha256": sha256(Path(frozen) / "manifest.json"),
        "model": str(Path(base).resolve()),
        "base_sha256": BASE_SHA256,
        "base_files": {str(p): sha256(p) for p in Path(base).iterdir() if p.is_file()},
        "seed": 20261028,
        "learning_rate": 1e-5,
        "batch_size": 1,
        "grad_accumulation_steps": 8,
        "num_layers": 4,
        "lora_parameters": {
            "rank": 8,
            "scale": 2.0,
            "dropout": 0.0,
            "keys": [
                "self_attn.q_proj",
                "self_attn.v_proj",
                "linear_attn.in_proj_qkv",
                "linear_attn.in_proj_z",
            ],
        },
        "mask_prompt": True,
        "max_seq_length": 3072 + answer_room,
        "answer_room": answer_room,
        "max_observed_prompt_tokens": max(p for p, _ in lengths),
        "max_observed_sequence_tokens": max(s for _, s in lengths),
        "expanded_counts": counts,
        "canonical_counts": manifest["split_counts"],
        "iters": iters,
        "checkpoint_steps": checkpoints,
        "code_hashes": code_hashes(),
        "runtime_versions": runtime_versions(),
        "fresh_base": True,
        "resume_adapter_file": None,
        "test_accessed": False,
        "selection": "validation macro F1, type-category accuracy, fewer invalid outputs, earlier step",
    }
    write_new(config, value)
    return value


def load_config(path):
    cfg = json.loads(Path(path).read_text())
    if cfg["runtime_versions"] != runtime_versions():
        raise ValueError("Frozen training/runtime dependency versions changed")
    manifest, data = verify_frozen(cfg["frozen"])
    if (
        sha256(Path(cfg["frozen"]) / "manifest.json") != cfg["manifest_sha256"]
        or cfg["policy_version"] != POLICY_VERSION
        or cfg["base_sha256"] != BASE_SHA256
    ):
        raise ValueError("Frozen configuration binding changed")
    for name, expected in {**cfg["code_hashes"], **cfg["base_files"]}.items():
        if sha256(name) != expected:
            raise ValueError(f"Frozen code/base changed: {name}")
    verify_base(cfg["model"])
    return cfg, data


def require_unopened(frozen):
    if (Path(frozen) / "test-access.json").exists():
        raise ValueError(
            "Held-out test was accessed; further fitting or selection on this corpus is forbidden"
        )


def selected_record(config, selection, *, locked=False):
    cfg, _ = load_config(config)
    selection = Path(selection)
    report = json.loads(selection.read_text())
    selected = report["selected"]
    if (
        report.get("config_sha256") != sha256(config)
        or report.get("test_accessed") is not False
        or sha256(selected["checkpoint"]) != selected["checkpoint_sha256"]
        or sha256(selected["prediction_path"]) != selected["prediction_sha256"]
    ):
        raise ValueError("Selected checkpoint, predictions, or frozen config changed")
    if locked:
        lock = json.loads(selection.with_name("selection-lock.json").read_text())
        if (
            lock.get("selection_sha256") != sha256(selection)
            or lock.get("checkpoint_sha256") != selected["checkpoint_sha256"]
            or lock.get("config_sha256") != sha256(config)
        ):
            raise ValueError("Immutable selection lock does not match")
    return cfg, report


def lock(config, selection):
    cfg, report = selected_record(config, selection)
    require_unopened(cfg["frozen"])
    value = {
        "selection_sha256": sha256(selection),
        "config_sha256": sha256(config),
        "checkpoint_sha256": report["selected"]["checkpoint_sha256"],
        "policy_version": POLICY_VERSION,
        "test_accessed": False,
    }
    write_new(Path(selection).with_name("selection-lock.json"), value)
    return value


def worker_for_model(model, tokenizer):
    from groundkeeper.constraints import DecisionGrammar

    worker = Worker()
    worker.model, worker.tokenizer = model, tokenizer
    worker.manifest = {"backend": "qwen_mlx", "prompt_version": "v2"}
    worker.identity = {"manifest_sha256": digest({"policy": POLICY_VERSION, "prompt": "v2"})}
    worker.grammar = DecisionGrammar(tokenizer)
    return worker


def predict_rows(worker, rows, output, model_sha256):
    """Use the actual production classify/qwen path, including forced review=true."""
    from groundkeeper.metrics import evaluate

    gold, predictions, artifacts = [], [], []
    invalid = 0
    for row in rows:
        for variant, inputs, answer in variants(row):
            request = {
                "policy_version": POLICY_VERSION,
                "model_manifest_sha256": worker.identity["manifest_sha256"],
                "part_id": row["id"],
                "job_id": "evidence-eval",
                "transaction_revision": 1,
                "input": inputs,
            }
            raw_answer = []
            original_qwen = getattr(worker, "qwen", None)
            if original_qwen:

                def capture_qwen(inputs, cancelled):
                    raw = original_qwen(inputs, cancelled)
                    raw_answer.append(dict(raw))
                    return raw

                worker.qwen = capture_qwen
            try:
                prediction = worker.classify(request, lambda: False)["decision"]
                error = None
            except Exception as exc:
                prediction = {"type": "unknown", "category": "other", "review": True}
                error = getattr(exc, "code", type(exc).__name__)
                invalid += 1
            finally:
                if original_qwen:
                    worker.qwen = original_qwen
            record = {
                "id": row["id"],
                "split": row["split"],
                "variant": variant,
                "input_sha256": digest(inputs),
                "model_sha256": model_sha256,
                "prediction": prediction,
                "raw_prediction": raw_answer[0] if raw_answer else prediction,
                "error": error,
            }
            record["prediction_sha256"] = digest(record)
            artifacts.append(record)
            gold.append(answer)
            predictions.append(prediction)
    write_new(output, artifacts, rows=True)
    metrics = evaluate(gold, predictions)
    metrics["type_category_accuracy"] = sum(
        (a["type"], a["category"]) == (b["type"], b["category"]) for a, b in zip(gold, predictions)
    ) / len(gold)
    metrics["raw_review_accuracy"] = sum(
        a["review"] == b["raw_prediction"]["review"] for a, b in zip(gold, artifacts)
    ) / len(gold)
    metrics["production_review_accuracy"] = metrics["review_accuracy"]
    production_indices = [i for i, a in enumerate(artifacts) if a["variant"] == "with_context"]
    production_gold = [gold[i] for i in production_indices]
    production_predictions = [predictions[i] for i in production_indices]
    metrics["production"] = evaluate(production_gold, production_predictions)
    metrics["production"]["type_category_accuracy"] = sum(
        (a["type"], a["category"]) == (b["type"], b["category"])
        for a, b in zip(production_gold, production_predictions)
    ) / len(production_gold)
    metrics["primary_cohort"] = (
        "with_context: actual captured input including rows where search found no evidence"
    )
    # Forced production review is expected; retain semantic review accuracy explicitly.
    return {
        "metrics": metrics,
        "invalid_outputs": invalid,
        "prediction_path": str(output),
        "prediction_sha256": sha256(output),
        "model_sha256": model_sha256,
        "policy_version": POLICY_VERSION,
        "test_accessed": False,
    }


def validate_replay(rows, predictions, verdicts):
    """TRAIN-only reviewed mistake replay, never automatic disagreement relabeling."""
    indexed = {(p["id"], p["variant"]): p for p in predictions}
    reviewed = {(v["id"], v["variant"]): v for v in verdicts}
    if len(indexed) != len(predictions) or len(reviewed) != len(verdicts):
        raise ValueError("Duplicate replay prediction or verdict")
    result = []
    for row in rows:
        if row["split"] != "train":
            raise ValueError("Replay cannot include validation or held-out rows")
        for variant, inputs, answer in variants(row):
            key = (row["id"], variant)
            if key not in reviewed:
                continue
            prediction, verdict = indexed[key], reviewed[key]
            if (
                prediction["split"] != "train"
                or prediction["input_sha256"] != digest(inputs)
                or prediction["prediction_sha256"]
                != digest({k: v for k, v in prediction.items() if k != "prediction_sha256"})
                or verdict.get("verdict") != "label_confirmed_model_wrong"
                or verdict.get("prediction_sha256") != prediction["prediction_sha256"]
                or verdict.get("input_sha256") != prediction["input_sha256"]
                or verdict.get("model_sha256") != prediction["model_sha256"]
                or verdict.get("answer_sha256") != digest(answer)
                or verdict.get("reviewer") != {"model": "gpt-6.1-sol", "reasoning_effort": "high"}
                or (prediction["prediction"]["type"], prediction["prediction"]["category"])
                == (answer["type"], answer["category"])
            ):
                raise ValueError("Replay requires a separately reviewed, hash-bound TRAIN mistake")
            result.append(
                {"id": row["id"], "variant": variant, "messages": messages_v2(inputs, answer)}
            )
    if set(reviewed) - {(r["id"], v) for r in rows for v, _, _ in variants(r)}:
        raise ValueError("Verdict refers to rows outside provided TRAIN corpus")
    return result


def package(
    base,
    checkpoint,
    adapter_config,
    destination,
    *,
    model_id,
    config=RUN / "config.json",
    selection=None,
):
    """Build a new verified Worker package; does not install or select it."""
    base, checkpoint, adapter_config = Path(base), Path(checkpoint), Path(adapter_config)
    destination = confined(destination, RUN)
    if destination.exists():
        raise FileExistsError(destination)
    selection_path = (
        Path(selection) if selection else Path(config).parent / "training/selection.json"
    )
    frozen_cfg, selection = selected_record(config, selection_path, locked=True)
    selected = selection["selected"]
    if (
        selection.get("config_sha256") != sha256(config)
        or selection.get("test_accessed") is not False
        or Path(selected["checkpoint"]).resolve() != checkpoint.resolve()
        or selected["checkpoint_sha256"] != sha256(checkpoint)
        or Path(frozen_cfg["model"]).resolve() != base.resolve()
    ):
        raise ValueError("Packaging requires the frozen validation-selected checkpoint")
    verify_base(base)
    cfg = json.loads(adapter_config.read_text())
    if cfg.get("num_layers") != 4 or cfg.get("lora_parameters", {}).get("rank") != 8:
        raise ValueError("Expected rank-8, last-four-layer adapter")
    if (
        adapter_config.resolve()
        != (Path(selected["checkpoint"]).parent / "adapter_config.json").resolve()
    ):
        raise ValueError("Adapter config must belong to the selected run")
    destination.mkdir(parents=True)
    try:
        (destination / "model").mkdir()
        for path in base.iterdir():
            if path.is_file():
                shutil.copy2(path, destination / "model" / path.name)
        (destination / "adapters").mkdir()
        shutil.copy2(checkpoint, destination / "adapters/adapters.safetensors")
        shutil.copy2(adapter_config, destination / "adapters/adapter_config.json")
        files = {
            str(p.relative_to(destination)): {"sha256": sha256(p), "bytes": p.stat().st_size}
            for p in destination.rglob("*")
            if p.is_file()
        }
        write_new(
            destination / "classifier.json",
            {
                "format_version": 1,
                "model_id": model_id,
                "backend": "qwen_mlx",
                "policy_version": POLICY_VERSION,
                "prompt_version": "v2",
                "model_directory": "model",
                "adapter_directory": "adapters",
                "files": files,
            },
        )
        verify_package(destination, lambda: False)
    except BaseException:
        shutil.rmtree(destination)
        raise
    return destination


def replay(frozen, predictions, verdicts, output):
    _, data = verify_frozen(frozen)
    require_unopened(frozen)
    result = validate_replay(data["train"], read_rows(predictions), read_rows(verdicts))
    write_new(confined(output, PRIVATE), result, rows=True)
    return {
        "n": len(result),
        "output": str(output),
        "prediction_sha256": sha256(predictions),
        "verdict_sha256": sha256(verdicts),
        "training_started": False,
    }


def predict_package_rows(package_path, rows, output, *, prompt_version="v2"):
    output = confined(output, PRIVATE)
    manifest, manifest_sha = verify_package(Path(package_path).resolve(), lambda: False)
    if manifest["backend"] != "qwen_mlx":
        raise ValueError("Qwen package required")
    original_prompt = manifest.get("prompt_version", "v1")
    manifest = {
        **manifest,
        "policy_version": POLICY_VERSION,
        "prompt_version": original_prompt if prompt_version == "package" else prompt_version,
    }
    worker = Worker()
    worker.prepare(Path(package_path).resolve(), manifest, manifest_sha)
    model_sha = (
        manifest["files"].get("adapters/adapters.safetensors", {}).get("sha256", manifest_sha)
    )
    try:
        report = predict_rows(worker, rows, output, model_sha)
        report.update(
            package_manifest_sha256=manifest_sha,
            configured_prompt_version=original_prompt,
            evaluated_prompt_version=manifest["prompt_version"],
            comparison="configured incumbent pipeline"
            if prompt_version == "package"
            else "controlled current-v2 prompt; weights comparison",
        )
        return report
    finally:
        worker.release()


def predict(config, package_path, output, split="valid", prompt_version="v2"):
    cfg, data = load_config(config)
    if split not in ("train", "valid"):
        raise ValueError("Held-out test is sealed for selection")
    return predict_package_rows(package_path, data[split], output, prompt_version=prompt_version)


def train(
    config,
    qwen_baseline,
    delaware_baseline,
    *,
    cycle_name=None,
    parent_selection=None,
    replay_predictions=None,
    replay_verdicts=None,
):
    cfg, data = load_config(config)
    require_unopened(cfg["frozen"])
    replay_rows, parent = [], None
    if cycle_name is not None:
        if not cycle_name or not all(c.isalnum() or c in "-_" for c in cycle_name):
            raise ValueError("Cycle name must be letters, digits, hyphens, or underscores")
        _, parent = selected_record(config, parent_selection, locked=True)
        replay_rows = validate_replay(
            data["train"], read_rows(replay_predictions), read_rows(replay_verdicts)
        )
        if not replay_rows:
            raise ValueError("A correction cycle requires independently reviewed TRAIN mistakes")
        parent_predictions = read_rows(replay_predictions)
        if any(
            r["model_sha256"] != parent["selected"]["checkpoint_sha256"] for r in parent_predictions
        ):
            raise ValueError(
                "Replay predictions must come from the explicitly selected parent checkpoint"
            )
        parent_adapter = json.loads(
            (Path(parent["selected"]["checkpoint"]).parent / "adapter_config.json").read_text()
        )
        if (
            parent_adapter.get("num_layers") != cfg["num_layers"]
            or parent_adapter.get("lora_parameters") != cfg["lora_parameters"]
        ):
            raise ValueError("Parent adapter architecture does not match frozen configuration")
        cfg = {
            **cfg,
            "iters": math.ceil((cfg["expanded_counts"]["train"] + len(replay_rows)) / 8) * 8,
        }
        cfg["checkpoint_steps"] = sorted(
            {max(8, math.ceil(cfg["iters"] * n / 3 / 8) * 8) for n in (1, 2, 3)}
        )
    out = confined(
        Path(config).parent / ("cycles/" + cycle_name if cycle_name else "training"), RUN
    )
    if out.exists():
        raise FileExistsError("Run exists; automatic restart is forbidden")
    os.environ.update(
        HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", TOKENIZERS_PARALLELISM="false"
    )
    out.mkdir(parents=True)
    namespace = digest(
        {"config_path": str(Path(config).resolve()), "config_sha256": sha256(config)}
    )[:16]
    predictions = PRIVATE / "predictions" / namespace / (cycle_name or "initial")
    write_new(out / "started.json", {"config_sha256": sha256(config), "pid": os.getpid()})
    write_new(
        out / "cycle-config.json",
        {
            "initial_config_sha256": sha256(config),
            "parent_selection_sha256": sha256(parent_selection) if parent else None,
            "parent_checkpoint_sha256": parent["selected"]["checkpoint_sha256"] if parent else None,
            "replay_predictions_sha256": sha256(replay_predictions) if parent else None,
            "replay_verdicts_sha256": sha256(replay_verdicts) if parent else None,
            "replay_n": len(replay_rows),
            "optimizer_resumed": False,
            "iters": cfg["iters"],
            "checkpoint_steps": cfg["checkpoint_steps"],
            "test_accessed": False,
        },
    )
    baselines = {}
    for name, path in [("qwen", qwen_baseline), ("qwen-delaware", delaware_baseline)]:
        baselines[name] = predict(config, path, predictions / f"baseline-{name}.valid.jsonl")
        baselines[name + "-configured"] = predict(
            config,
            path,
            predictions / f"baseline-{name}-configured.valid.jsonl",
            prompt_version="package",
        )
    write_new(out / "baselines.json", baselines)
    import mlx.core as mx
    import numpy as np
    from mlx.utils import tree_flatten
    from mlx_lm import load
    from mlx_lm.lora import CONFIG_DEFAULTS, train_model
    from mlx_lm.tuner.callbacks import TrainingCallback
    from mlx_lm.tuner.datasets import ChatDataset

    mx.set_memory_limit(14_000_000_000)
    mx.set_cache_limit(512_000_000)
    np.random.seed(cfg["seed"])
    mx.random.seed(cfg["seed"])
    model, tokenizer = load(cfg["model"], tokenizer_config={"trust_remote_code": False})
    datasets = []
    for split in ("train", "valid"):
        messages = []
        for row in data[split]:
            for _, inputs, answer in variants(row):
                token_check(tokenizer, inputs, answer, cfg["answer_room"])
                messages.append({"messages": messages_v2(inputs, answer)})
        if split == "train":
            messages.extend({"messages": r["messages"]} for r in replay_rows)
        dataset = ChatDataset(messages, tokenizer, mask_prompt=True)
        for item in dataset._data:
            tokens, offset = dataset.process(item)
            prefix = tokenizer.apply_chat_template(
                item["messages"][:-1],
                tokenize=True,
                add_generation_prompt=True,
                enable_thinking=False,
                return_dict=False,
            )
            if tokens[:offset] != prefix or not 0 < offset < len(tokens) <= cfg["max_seq_length"]:
                raise ValueError("MLX assistant-only loss or no-truncation preflight failed")
        datasets.append(dataset)
    reports = []

    class Callback(TrainingCallback):
        def on_val_loss_report(self, report):
            if parent and report.get("iteration") == 0:
                expected = mx.load(parent["selected"]["checkpoint"])
                actual = dict(tree_flatten(model.trainable_parameters()))
                if set(expected) != set(actual) or any(
                    not bool(mx.array_equal(expected[k], actual[k]).item()) for k in expected
                ):
                    raise ValueError(
                        "Parent adapter did not resume exactly before the first update"
                    )

        def on_train_loss_report(self, report):
            step = report["iteration"]
            if step not in cfg["checkpoint_steps"]:
                return
            checkpoint = out / "adapters" / f"{step:07d}_adapters.safetensors"
            mx.save_safetensors(str(checkpoint), dict(tree_flatten(model.trainable_parameters())))
            state = np.random.get_state()
            model.eval()
            try:
                result = predict_rows(
                    worker_for_model(model, tokenizer),
                    data["valid"],
                    predictions / f"checkpoint-{step:07d}.valid.jsonl",
                    sha256(checkpoint),
                )
            finally:
                model.train()
                np.random.set_state(state)
            result.update(
                step=step, checkpoint=str(checkpoint), checkpoint_sha256=sha256(checkpoint)
            )
            write_new(out / f"validation-{step:07d}.json", result)
            reports.append(result)

    native = {
        **CONFIG_DEFAULTS,
        **{
            k: cfg[k]
            for k in (
                "model",
                "num_layers",
                "batch_size",
                "grad_accumulation_steps",
                "iters",
                "learning_rate",
                "max_seq_length",
                "seed",
                "lora_parameters",
            )
        },
        "adapter_path": str(out / "adapters"),
        "fine_tune_type": "lora",
        "optimizer": "adam",
        "optimizer_config": {},
        "grad_checkpoint": True,
        "mask_prompt": True,
        "steps_per_report": 8,
        "steps_per_eval": cfg["iters"],
        "val_batches": 8,
        "save_every": cfg["iters"],
        "resume_adapter_file": parent["selected"]["checkpoint"] if parent else None,
        "train": True,
        "test": False,
        "report_to": None,
        "trust_remote_code": False,
    }
    train_model(SimpleNamespace(**native), model, datasets[0], datasets[1], Callback())
    if sorted(r["step"] for r in reports) != cfg["checkpoint_steps"]:
        raise ValueError("Missing saved checkpoint evaluations")
    eligible = reports + ([{**parent["selected"], "parent_incumbent": True}] if parent else [])
    best = max(
        eligible,
        key=lambda r: (
            r["metrics"]["production"]["macro_f1_supported_categories"],
            r["metrics"]["production"]["type_category_accuracy"],
            -r["invalid_outputs"],
            r.get("parent_incumbent", False),
            -r["step"],
        ),
    )
    write_new(
        out / "selection.json",
        {
            "selected": best,
            "checkpoints": reports,
            "config_sha256": sha256(config),
            "test_accessed": False,
            "baselines": baselines,
            "automatic_promotion": False,
            "cycle_config_sha256": sha256(out / "cycle-config.json"),
            "parent_selection_sha256": sha256(parent_selection) if parent else None,
        },
    )
    return best


def cycle(
    config,
    qwen_baseline,
    delaware_baseline,
    cycle_name,
    parent_selection,
    replay_predictions,
    replay_verdicts,
):
    return train(
        config,
        qwen_baseline,
        delaware_baseline,
        cycle_name=cycle_name,
        parent_selection=parent_selection,
        replay_predictions=replay_predictions,
        replay_verdicts=replay_verdicts,
    )


def final_score(
    config,
    selection,
    package_path,
    qwen_baseline,
    delaware_baseline,
    output=RUN / "final-report.json",
):
    """One final test access after immutable selection. Failure never reopens fitting."""
    from .evaluation import paired_report

    cfg, selected = selected_record(config, selection, locked=True)
    frozen = Path(cfg["frozen"])
    require_unopened(frozen)
    output = confined(output, RUN)
    if output.exists():
        raise FileExistsError(output)
    package_manifest, _ = verify_package(Path(package_path).resolve(), lambda: False)
    if (
        package_manifest["files"].get("adapters/adapters.safetensors", {}).get("sha256")
        != selected["selected"]["checkpoint_sha256"]
    ):
        raise ValueError("Final package does not contain the locked selected checkpoint")
    # Validate all packages before consuming the one-shot final access.
    for baseline in (qwen_baseline, delaware_baseline):
        verify_package(Path(baseline).resolve(), lambda: False)
    manifest = json.loads((frozen / "manifest.json").read_text())
    write_new(
        frozen / "test-access.json",
        {
            "selection_lock_sha256": sha256(Path(selection).with_name("selection-lock.json")),
            "config_sha256": sha256(config),
            "pid": os.getpid(),
            "purpose": "one-shot final heldout scoring",
            "further_fitting_forbidden": True,
            "failure_also_consumes_holdout": True,
        },
    )
    if sha256(frozen / "test.jsonl") != manifest["split_hashes"]["test"]:
        raise ValueError("Sealed held-out payload changed")
    rows = read_rows(frozen / "test.jsonl")
    registry = validate_registry(read_rows(frozen / "historical-family-registry.jsonl"))
    validate_rows(rows, registry)
    ledger = read_rows(frozen / "split-manifest.jsonl")
    if (
        len(rows) != manifest["split_counts"]["test"]
        or any(r["split"] != "test" for r in rows)
        or {r["id"] for r in rows} != {r["id"] for r in ledger if r["split"] == "test"}
    ):
        raise ValueError("Sealed held-out membership mismatch")
    pred_dir = (
        PRIVATE
        / "predictions"
        / digest({"config_sha256": sha256(config), "selection_sha256": sha256(selection)})[:16]
        / "final"
    )
    candidate = predict_package_rows(package_path, rows, pred_dir / "candidate.test.jsonl")
    candidate["test_accessed"] = True
    predictions = read_rows(candidate["prediction_path"])
    comparisons = {}
    for name, baseline in [("qwen", qwen_baseline), ("qwen-delaware", delaware_baseline)]:
        for prompt in ("v2", "package"):
            label = name if prompt == "v2" else name + "-configured"
            result = predict_package_rows(
                baseline, rows, pred_dir / f"{label}.test.jsonl", prompt_version=prompt
            )
            result["test_accessed"] = True
            comparisons[label] = {
                "baseline": result,
                "paired_comparison": paired_report(
                    rows, predictions, read_rows(result["prediction_path"])
                ),
            }
    report = {
        "config_sha256": sha256(config),
        "selection_sha256": sha256(selection),
        "selection_lock_sha256": sha256(Path(selection).with_name("selection-lock.json")),
        "test_access_marker_sha256": sha256(frozen / "test-access.json"),
        "candidate": candidate,
        "comparisons": comparisons,
        "test_accessed": True,
        "further_fitting_forbidden": True,
        "automatic_promotion": False,
        "target_accuracy_improvement_pp": 10,
        "target_note": "Reported ambition only; final failure requires a new untouched holdout before further model selection.",
    }
    write_new(output, report)
    return report


def main():
    parser = argparse.ArgumentParser(__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    freeze_p = sub.add_parser("freeze")
    freeze_p.add_argument("--labels", type=Path, required=True)
    freeze_p.add_argument("--acceptance", type=Path, required=True)
    freeze_p.add_argument("--family-registry", type=Path, required=True)
    freeze_p.add_argument("--destination", type=Path, default=PRIVATE / "frozen")
    pre = sub.add_parser("preflight")
    pre.add_argument("--frozen", type=Path, default=PRIVATE / "frozen")
    pre.add_argument("--config", type=Path, default=RUN / "config.json")
    pre.add_argument("--base", type=Path, default=BASE)
    tr = sub.add_parser("train")
    tr.add_argument("--config", type=Path, default=RUN / "config.json")
    tr.add_argument("--qwen-baseline", type=Path, required=True)
    tr.add_argument("--delaware-baseline", type=Path, required=True)
    pred = sub.add_parser("predict")
    pred.add_argument("--config", type=Path, default=RUN / "config.json")
    pred.add_argument("--package-path", type=Path, required=True)
    pred.add_argument("--output", type=Path, required=True)
    pred.add_argument("--split", choices=("train", "valid"), default="valid")
    pred.add_argument("--prompt-version", choices=("v2", "package"), default="v2")
    pack = sub.add_parser("package")
    pack.add_argument("--base", type=Path, default=BASE)
    pack.add_argument("--checkpoint", type=Path, required=True)
    pack.add_argument("--adapter-config", type=Path, required=True)
    pack.add_argument("--destination", type=Path, default=RUN / "package")
    pack.add_argument("--model-id", default="qwen-evidence-v3")
    pack.add_argument("--config", type=Path, default=RUN / "config.json")
    pack.add_argument("--selection", type=Path)
    replay_p = sub.add_parser("replay")
    replay_p.add_argument("--frozen", type=Path, default=PRIVATE / "frozen")
    replay_p.add_argument("--predictions", type=Path, required=True)
    replay_p.add_argument("--verdicts", type=Path, required=True)
    replay_p.add_argument("--output", type=Path, required=True)
    cyc = sub.add_parser("cycle")
    cyc.add_argument("--config", type=Path, default=RUN / "config.json")
    cyc.add_argument("--qwen-baseline", type=Path, required=True)
    cyc.add_argument("--delaware-baseline", type=Path, required=True)
    cyc.add_argument("--cycle-name", required=True)
    cyc.add_argument("--parent-selection", type=Path, required=True)
    cyc.add_argument("--replay-predictions", type=Path, required=True)
    cyc.add_argument("--replay-verdicts", type=Path, required=True)
    lock_p = sub.add_parser("lock")
    lock_p.add_argument("--config", type=Path, default=RUN / "config.json")
    lock_p.add_argument("--selection", type=Path, required=True)
    final = sub.add_parser("final-score")
    final.add_argument("--config", type=Path, default=RUN / "config.json")
    final.add_argument("--selection", type=Path, required=True)
    final.add_argument("--package-path", type=Path, required=True)
    final.add_argument("--qwen-baseline", type=Path, required=True)
    final.add_argument("--delaware-baseline", type=Path, required=True)
    final.add_argument("--output", type=Path, default=RUN / "final-report.json")
    args = vars(parser.parse_args())
    command = args.pop("command")
    result = globals()[command.replace("-", "_")](**args)
    print(json.dumps(result, default=str, indent=2))


if __name__ == "__main__":
    main()
