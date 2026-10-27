"""Evaluation and immutable checkpoint selection for the approved full run."""

import json
import time
from pathlib import Path

from groundkeeper.metrics import evaluate
from groundkeeper.runtime import generate_answer
from scripts.common_io import write_json

ROOT = Path(".local/finetune")
RUN = ROOT / "full-v1"


def evaluate_rows(model, tokenizer, rows, output_prefix, seconds=180):
    start = time.monotonic()
    predictions = []
    raw = []
    invalid = repaired = 0
    for row in rows:
        if time.monotonic() - start > seconds:
            raise TimeoutError(f"Evaluation exceeded {seconds} seconds")
        answer, detail = generate_answer(model, tokenizer, row["input"])
        predictions.append(answer)
        raw.append({"id": row["id"], "prediction": answer, **detail})
        invalid += not detail["valid_schema"]
        repaired += detail["removed_json_fence"]
    metrics = evaluate([row["answer"] for row in rows], predictions)
    for source in sorted({row["source"] for row in rows}):
        ix = [i for i, row in enumerate(rows) if row["source"] == source]
        metrics.setdefault("by_source", {})[source] = evaluate(
            [rows[i]["answer"] for i in ix], [predictions[i] for i in ix]
        )
    report = {
        "metrics": metrics,
        "invalid_outputs": invalid,
        "format_repaired_outputs": repaired,
        "elapsed_seconds": time.monotonic() - start,
        "mean_latency_seconds": sum(r["latency_seconds"] for r in raw) / len(raw),
    }
    prefix = Path(output_prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    prefix.with_suffix(".jsonl").write_text("".join(json.dumps(r) + "\n" for r in raw))
    write_json(prefix.with_suffix(".json"), report)
    return report


def selection_key(report):
    return (
        report["metrics"]["macro_f1_supported_categories"],
        report["metrics"]["joint_accuracy"],
        -report["invalid_outputs"],
        -report["step"],
    )


def choose_checkpoint(reports, expected_steps=(128, 256, 384, 512, 632)):
    if sorted(r["step"] for r in reports) != list(expected_steps):
        raise ValueError("Every planned checkpoint must have one validation report")
    return max(reports, key=selection_key)
