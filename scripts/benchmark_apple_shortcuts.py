"""Resumable serial validation benchmark; final-test partitions are never opened."""
import argparse
import hashlib
import json
import statistics
import time
from datetime import datetime, timezone
from pathlib import Path

from groundkeeper.apple_shortcuts import ShortcutExecutionError, run_shortcut
from groundkeeper.metrics import evaluate

VALIDATION = Path(".local/finetune/v2/prepared/valid_records.jsonl")
QWEN = Path(".local/finetune/v2/training/candidate-0/validation-0002080.jsonl")
CONFIG = Path("experiments/apple-shortcuts/config.json")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_rows(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2)+"\n")
    temporary.replace(path)


def summarize(rows, records, qwen):
    completed = {r["id"]: r for r in records if r["status"] in ("ok", "invalid_output")}
    scored = [r for r in rows if r["id"] in completed]
    valid = [r for r in scored if completed[r["id"]]["valid_schema"]]
    gold = [r["answer"] for r in valid]
    predictions = [completed[r["id"]]["prediction"] for r in valid]
    metrics = evaluate(gold, predictions) if valid else None
    # Invalid outputs receive zero credit, even if an abstention would match gold.
    all_accuracy = {}
    for field in ("category", "type", "review"):
        hits = sum(completed[r["id"]]["valid_schema"] and
                   completed[r["id"]]["prediction"][field] == r["answer"][field]
                   for r in scored)
        all_accuracy[field+"_accuracy"] = hits/len(scored) if scored else None
    hits = sum(completed[r["id"]]["valid_schema"] and
               completed[r["id"]]["prediction"] == r["answer"] for r in scored)
    all_accuracy["joint_accuracy"] = hits/len(scored) if scored else None
    latencies = [completed[r["id"]]["latency_seconds"] for r in scored]
    report = {"dataset_n": len(rows), "completed_n": len(scored), "valid_n": len(valid),
              "invalid_outputs": len(scored)-len(valid),
              "execution_errors": sum(r["status"] in ("timeout", "execution_error") for r in records),
              "all_completed_accuracy": all_accuracy, "valid_output_metrics": metrics,
              "mean_latency_seconds": statistics.mean(latencies) if latencies else None,
              "median_latency_seconds": statistics.median(latencies) if latencies else None,
              "real_data": False, "application_review_required": True,
              "baseline": "Qwen v2 candidate 0, step 2080; saved predictions, no rerun",
              "full_qwen_metrics": evaluate([r["answer"] for r in rows], [qwen[r["id"]] for r in rows]),
              "qwen_metrics_on_completed_subset": evaluate([r["answer"] for r in scored],
                  [qwen[r["id"]] for r in scored]) if scored else None,
              "errors": [{"id": r["id"], "input": r["input"], "gold": r["answer"],
                          "prediction": completed[r["id"]].get("prediction"),
                          "status": completed[r["id"]]["status"]}
                         for r in scored if completed[r["id"]].get("prediction") != r["answer"]]}
    if valid:
        report["by_source"] = {}
        for source in sorted({r["source"] for r in valid}):
            subset = [r for r in valid if r["source"] == source]
            report["by_source"][source] = evaluate([r["answer"] for r in subset],
                [completed[r["id"]]["prediction"] for r in subset])
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=CONFIG)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=279)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--session-seconds", type=float, default=3600)
    parser.add_argument("--interval", type=float, default=1)
    args = parser.parse_args()
    if args.limit < 1 or args.timeout <= 0 or args.session_seconds <= 0 or args.interval < 0:
        parser.error("Invalid benchmark bounds")
    config = json.loads(args.config.read_text())
    rows = read_rows(VALIDATION)
    if any(r["split"] != "valid" for r in rows):
        raise ValueError("Only validation examples are permitted")
    qwen_records = read_rows(QWEN)
    qwen = {r["id"]: r["prediction"] for r in qwen_records}
    if len(qwen) != len(rows) or set(qwen) != {r["id"] for r in rows}:
        raise ValueError("Qwen comparison IDs must match the complete validation set")
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = {"validation_sha256": digest(VALIDATION), "qwen_predictions_sha256": digest(QWEN),
                "config_sha256": digest(args.config), "config": config,
                "prompt_sha256": digest(Path(config["prompt_path"])),
                "validation_n": len(rows), "payload_fields": ["description", "direction", "currency"],
                "gold_labels_sent": False}
    manifest_path = args.output/"manifest.json"
    if manifest_path.exists():
        if json.loads(manifest_path.read_text()) != manifest:
            raise ValueError("Cannot resume with a changed dataset, prompt, or configuration")
    else:
        write_json(manifest_path, manifest)
    log = args.output/"responses.jsonl"
    records = read_rows(log) if log.exists() else []
    completed = {r["id"] for r in records if r["status"] in ("ok", "invalid_output")}
    start = time.monotonic()
    stop_reason = None
    for row in rows[:args.limit]:
        if row["id"] in completed:
            continue
        remaining = args.session_seconds-(time.monotonic()-start)
        if remaining <= 0:
            stop_reason = "session_time_limit"
            break
        stamp = datetime.now(timezone.utc).isoformat()
        try:
            answer, detail = run_shortcut(row["input"], config["shortcut_name"],
                                          min(args.timeout, remaining))
            record = {"id": row["id"], "requested_at": stamp, "prediction": answer, **detail}
        except ShortcutExecutionError as error:
            record = {"id": row["id"], "requested_at": stamp, "message": str(error), **error.detail}
            if record["status"] != "invalid_output":
                stop_reason = record["status"]+": "+str(error)
        records.append(record)
        with log.open("a") as stream:
            stream.write(json.dumps(record, ensure_ascii=False)+"\n")
            stream.flush()
        report = summarize(rows, records, qwen)
        report.update(status="stopped" if stop_reason else "running", stop_reason=stop_reason,
                      session_elapsed_seconds=time.monotonic()-start)
        write_json(args.output/"report.json", report)
        print(json.dumps({"done": report["completed_n"], "target": min(args.limit, len(rows)),
                          "status": record["status"], "latency_seconds": record["latency_seconds"],
                          "category_accuracy": report["all_completed_accuracy"]["category_accuracy"]}), flush=True)
        if stop_reason:
            break
        if args.interval:
            time.sleep(min(args.interval, max(0, args.session_seconds-(time.monotonic()-start))))
    report = summarize(rows, records, qwen)
    report.update(status="stopped" if stop_reason else ("complete" if report["completed_n"] == len(rows) else "partial"),
                  stop_reason=stop_reason, session_elapsed_seconds=time.monotonic()-start)
    write_json(args.output/"report.json", report)
    if stop_reason:
        raise SystemExit(stop_reason)


if __name__ == "__main__":
    main()
