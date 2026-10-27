"""Shared v2 evaluation, fixed checkpoint schedule, and integrity gates."""

import json
import math
import time
from pathlib import Path

from groundkeeper.constraints import DecisionGrammar
from groundkeeper.metrics import evaluate
from groundkeeper.policy import messages
from groundkeeper.policy_v2 import messages_v2
from groundkeeper.runtime_v2 import generate_decision
from scripts.common_io import sha256, write_json

ROOT = Path(".local/finetune")
OUT = ROOT / "v2"
RUN = OUT / "training"
PUBLIC = Path("experiments/finetune/v2")
CONFIG = PUBLIC / "training_config.json"


def checkpoint_steps(train_n):
    updates = math.ceil(train_n / 8)
    if updates < 3:
        raise ValueError("Insufficient data for three distinct checkpoints")
    return sorted({8 * math.ceil(updates * fraction / 3) for fraction in (1, 2, 3)})


def load_config():
    cfg = json.loads(CONFIG.read_text())
    if cfg["learning_rates"] != [5e-5, 2e-5] or cfg["epochs"] != 1:
        raise ValueError("Unexpected finite experiment configuration")
    for name, digest in cfg["data_hashes"].items():
        if sha256(OUT / "prepared" / name) != digest:
            raise ValueError("Frozen training/validation data changed")
    for name, digest in cfg["code_hashes"].items():
        if sha256(name) != digest:
            raise ValueError(f"Code changed after preflight: {name}")
    if sha256(ROOT / "prepared/valid_records.jsonl") != cfg["legacy_validation_sha256"]:
        raise ValueError("Legacy validation changed")
    return cfg


def score_key(report):
    return (
        report["metrics"]["macro_f1_supported_categories"],
        report["metrics"]["joint_accuracy"],
        -report["invalid_outputs"],
        -report["step"],
        -report["candidate"],
    )


def choose(reports, steps, candidates=(0, 1)):
    expected = {(candidate, step) for candidate in candidates for step in steps}
    actual = [(r["candidate"], r["step"]) for r in reports]
    if len(actual) != len(expected) or set(actual) != expected:
        raise ValueError("Every planned checkpoint must have exactly one completed validation")
    return max(reports, key=score_key)


def evaluate_rows(model, tokenizer, rows, prefix, mode="constrained", prompt="v2", seconds=1200):
    prefix = Path(prefix)
    if prefix.with_suffix(".json").exists() or prefix.with_suffix(".jsonl").exists():
        raise FileExistsError(f"Evaluation already exists: {prefix}")
    start = time.monotonic()
    grammar = DecisionGrammar(tokenizer)
    raw = []
    builder = messages_v2 if prompt == "v2" else messages
    for index, row in enumerate(rows):
        if time.monotonic() - start > seconds:
            raise TimeoutError(f"Evaluation exceeded {seconds} seconds")
        answer, detail = generate_decision(model, tokenizer, row["input"], grammar, mode, builder)
        raw.append({"id": row["id"], "prediction": answer, **detail})
        if (index + 1) % 50 == 0:
            print(
                json.dumps({"evaluation": prefix.name, "done": index + 1, "n": len(rows)}),
                flush=True,
            )
    gold = [r["answer"] for r in rows]
    predicted = [r["prediction"] for r in raw]
    metrics = evaluate(gold, predicted)
    for field, extract in [
        ("by_source", lambda r: r["source"]),
        ("by_currency", lambda r: r["input"]["currency"]),
        ("by_gold_type", lambda r: r["answer"]["type"]),
    ]:
        metrics[field] = {}
        for value in sorted({extract(r) for r in rows}):
            ix = [i for i, r in enumerate(rows) if extract(r) == value]
            metrics[field][value] = evaluate([gold[i] for i in ix], [predicted[i] for i in ix])
    report = {
        "metrics": metrics,
        "invalid_outputs": sum(not r["valid_schema"] for r in raw),
        "draft_invalid_outputs": sum(r["draft_invalid"] for r in raw),
        "constrained_retries": sum(r["constrained_retry"] for r in raw),
        "mode": mode,
        "prompt_version": prompt,
        "elapsed_seconds": time.monotonic() - start,
        "mean_latency_seconds": sum(r["latency_seconds"] for r in raw) / len(raw),
        "real_data": False,
        "application_review_required": True,
    }
    prefix.parent.mkdir(parents=True, exist_ok=True)
    prefix.with_suffix(".jsonl").write_text("".join(json.dumps(r) + "\n" for r in raw))
    write_json(prefix.with_suffix(".json"), report)
    return report
