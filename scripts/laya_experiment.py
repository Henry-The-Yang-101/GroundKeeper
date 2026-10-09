"""Bounded local Laya benchmark/fine-tune; never reads the sealed test.

Use the isolated interpreter in .local/laya/.venv. The original files, frozen
Qwen data/checkpoints and old experiment paths are never overwritten.
"""
import argparse
import hashlib
import importlib.metadata
import json
import os
import shutil
import statistics
import time
from dataclasses import asdict
from pathlib import Path

os.environ.update(HF_HUB_OFFLINE="1", HF_HUB_DISABLE_TELEMETRY="1", TOKENIZERS_PARALLELISM="false")

from groundkeeper.laya_runtime import HEAD_MAX_LEN, MAX_LEN, QUESTIONS, LocalLayaCategorizer, configure_agent, decode, training_row
from groundkeeper.metrics import evaluate
from groundkeeper.policy import validate_answer
from scripts.full_common import read_rows, sha256, write_json

ROOT = Path(".local/laya")
PUBLIC = Path("experiments/laya")
ORIGINAL = ROOT / "base-original"
BASE = ROOT / "base-prepared"
PREPARED = ROOT / "prepared"
SOURCE = Path(".local/finetune/v2/prepared")
REVISION = "55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851"
CONFIG = PUBLIC / "training_config.json"


def manifest(path):
    return {str(p.relative_to(path)): {"sha256": sha256(p), "bytes": p.stat().st_size}
            for p in sorted(path.rglob("*")) if p.is_file() and ".cache" not in p.parts}


def versions():
    return {name: importlib.metadata.version(name) for name in ("laya", "torch", "transformers", "safetensors", "numpy")}


def check_integrity():
    data = json.loads((PREPARED / "manifest.json").read_text())
    for split in ("train", "valid"):
        if sha256(SOURCE / f"{split}_records.jsonl") != data["source_sha256"][split]:
            raise ValueError("Frozen source changed")
        if sha256(PREPARED / f"{split}.jsonl") != data["prepared_sha256"][split]:
            raise ValueError("Prepared Laya data changed")
    if manifest(ORIGINAL) != data["original_files"]:
        raise ValueError("Original checkpoint changed")
    if manifest(BASE) != data["base_files"]:
        raise ValueError("Prepared base changed")
    if hashlib.sha256(json.dumps(QUESTIONS, sort_keys=True).encode()).hexdigest() != data["question_sha256"]:
        raise ValueError("Question schema changed")
    return data


def prepare():
    if PREPARED.exists() or BASE.exists():
        raise FileExistsError("Laya preparation already exists")
    cfg = json.loads(Path("experiments/finetune/v2/training_config.json").read_text())
    rows = {split: read_rows(SOURCE / f"{split}_records.jsonl") for split in ("train", "valid")}
    for split in rows:
        if sha256(SOURCE / f"{split}_records.jsonl") != cfg["data_hashes"][f"{split}_records.jsonl"]:
            raise ValueError("Source differs from frozen Qwen data")
    if len(rows["train"]) != 2077 or len(rows["valid"]) != 279:
        raise ValueError("Unexpected data counts")
    if {r["merchant_group"] for r in rows["train"]} & {r["merchant_group"] for r in rows["valid"]}:
        raise ValueError("Merchant groups overlap")
    original = manifest(ORIGINAL)
    shutil.copytree(ORIGINAL, BASE, ignore=shutil.ignore_patterns(".cache"))
    from laya.agent import _fix_tokenizer_config
    _fix_tokenizer_config(str(BASE))
    from transformers import AutoTokenizer
    from laya.common import build_head, build_sequence, encode_text, serialize_state
    from laya.train import items_from_rows, to_internal
    tokenizer = AutoTokenizer.from_pretrained(BASE / "tokenizer", local_files_only=True)
    heads = {}
    for field, question in QUESTIONS.items():
        internal = to_internal(field, question)
        head, markers, stats = build_head(tokenizer, internal, HEAD_MAX_LEN)
        full_head, _, _ = build_head(tokenizer, internal, 2048)
        if head != full_head or stats["options_distinct"] != stats["options"]:
            raise ValueError(f"Truncated or collapsed {field} question")
        heads[field] = {"tokens": len(head), "options": len(markers)}
    PREPARED.mkdir()
    maximum = 0
    for split, records in rows.items():
        converted = [training_row(r) for r in records]
        items, skipped = items_from_rows(tokenizer, converted, MAX_LEN, HEAD_MAX_LEN)
        if skipped or len(items) != 3 * len(records):
            raise ValueError(f"Invalid training conversion: {skipped}")
        for row in converted:
            state = encode_text(tokenizer, serialize_state(row["state"]).replace(tokenizer.mask_token, " "), add_special_tokens=False)["input_ids"]
            for field, question in QUESTIONS.items():
                head_length = heads[field]["tokens"]
                if head_length + len(state) + 1 > MAX_LEN:
                    raise ValueError("State would be truncated")
                seq, markers = build_sequence(tokenizer, row["state"], to_internal(field, question), MAX_LEN, HEAD_MAX_LEN)
                maximum = max(maximum, len(seq))
                if len(markers) != len(question["criteria"]):
                    raise ValueError("Option marker missing")
        (PREPARED / f"{split}.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in converted))
    report = {"source_sha256": {s: sha256(SOURCE / f"{s}_records.jsonl") for s in rows},
              "prepared_sha256": {s: sha256(PREPARED / f"{s}.jsonl") for s in rows},
              "rows": {s: len(r) for s, r in rows.items()}, "train_decisions": 6231,
              "questions": QUESTIONS, "heads": heads, "maximum_sequence_tokens": maximum,
              "max_len": MAX_LEN, "head_max_len": HEAD_MAX_LEN,
              "question_sha256": hashlib.sha256(json.dumps(QUESTIONS, sort_keys=True).encode()).hexdigest(),
              "checkpoint_repo": "convaiinnovations/laya", "checkpoint_revision": REVISION,
              "original_files": original, "base_files": manifest(BASE), "versions": versions(),
              "sealed_test_read": False, "real_data": False, "labels": "synthetic_ai_reviewed_not_human"}
    write_json(PREPARED / "manifest.json", report)
    write_json(PUBLIC / "preparation_report.json", report)
    print(json.dumps({k: report[k] for k in ("rows", "train_decisions", "heads", "maximum_sequence_tokens", "versions")}), flush=True)


def score(agent, rows, path, seconds=900):
    import torch
    path = Path(path)
    if path.with_suffix(".json").exists():
        raise FileExistsError(path)
    agent.model.eval()
    if agent.device.type != "mps" or next(agent.model.parameters()).device.type != "mps":
        raise RuntimeError("Expected MPS model")
    # Warm the exact three-question, single-transaction deployment shape.
    agent.predict(rows[0]["input"], QUESTIONS, max_len=MAX_LEN, head_max_len=HEAD_MAX_LEN)
    torch.mps.synchronize()
    start = time.monotonic()
    predictions = []
    for i, row in enumerate(rows):
        if time.monotonic() - start > seconds:
            raise TimeoutError("Laya validation time bound")
        before = time.perf_counter()
        result = agent.predict(row["input"], QUESTIONS, max_len=MAX_LEN, head_max_len=HEAD_MAX_LEN)
        torch.mps.synchronize()
        answer, detail = decode(result["answers"])
        validate_answer(answer)
        predictions.append({"id": row["id"], "prediction": answer, **detail,
                            "latency_seconds": time.perf_counter() - before})
        if (i + 1) % 50 == 0:
            print(json.dumps({"validation": path.name, "done": i + 1, "n": len(rows)}), flush=True)
    metrics = evaluate([r["answer"] for r in rows], [p["prediction"] for p in predictions])
    for field, get in (("by_source", lambda r: r["source"]), ("by_currency", lambda r: r["input"]["currency"]),
                       ("by_gold_type", lambda r: r["answer"]["type"])):
        metrics[field] = {}
        for value in sorted({get(r) for r in rows}):
            ix = [i for i, r in enumerate(rows) if get(r) == value]
            metrics[field][value] = evaluate([rows[i]["answer"] for i in ix], [predictions[i]["prediction"] for i in ix])
    raw = [p["raw_prediction"] for p in predictions]
    latencies = [p["latency_seconds"] for p in predictions]
    if agent.device.type != "mps" or next(agent.model.parameters()).device.type != "mps":
        raise RuntimeError("Model left MPS during validation")
    report = {"metrics": metrics,
              "raw_field_accuracy": {f: sum(p is not None and p[f] == r["answer"][f] for p, r in zip(raw, rows)) / len(rows) for f in QUESTIONS},
              "raw_invalid_combinations": sum(not p["raw_valid_schema"] for p in predictions),
              "constraint_changed": sum(p["constraint_changed"] for p in predictions),
              "invalid_outputs": sum(not p["valid_schema"] for p in predictions),
              "elapsed_seconds": time.monotonic() - start,
              "mean_latency_seconds": statistics.mean(latencies), "median_latency_seconds": statistics.median(latencies),
              "p95_latency_seconds": sorted(latencies)[min(len(latencies) - 1, int(len(latencies) * .95))],
              "device": str(next(agent.model.parameters()).device), "precision": "fp32",
              "temperature": 1.0, "decoder": "joint_schema_constrained",
              "validation_sha256": sha256(SOURCE / "valid_records.jsonl"),
              "real_data": False, "application_review_required": True, "sealed_test_read": False}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.with_suffix(".jsonl").write_text("".join(json.dumps(p) + "\n" for p in predictions))
    write_json(path.with_suffix(".json"), report)
    print(json.dumps({"validation": str(path), "category_accuracy": metrics["category_accuracy"],
                      "joint_accuracy": metrics["joint_accuracy"], "macro_f1": metrics["macro_f1_supported_categories"],
                      "raw_invalid": report["raw_invalid_combinations"], "latency": report["mean_latency_seconds"]}), flush=True)
    return report


def baseline():
    check_integrity()
    runtime = LocalLayaCategorizer(BASE)
    report = score(runtime.agent, read_rows(SOURCE / "valid_records.jsonl"), ROOT / "baseline")
    write_json(PUBLIC / "baseline.json", report)


def train_config(epochs):
    from laya.train import TrainConfig
    # 6,231 typed decisions, not 2,077 optimizer updates. Supervised labels use
    # upstream soft-CE; all encoder parameters train, with checkpointed activations.
    return TrainConfig(epochs=epochs, micro_batch=2, grad_accum=16,
                       encoder_lr=2.5e-5, head_lr=1e-4, loss="soft-ce",
                       shuffle_options=("choice",), calib_frac=0, calib_max=0,
                       seed=20261009, max_len=MAX_LEN, head_max_len=HEAD_MAX_LEN,
                       amp=False, gradient_checkpointing=True, log_every=25)


def probe():
    check_integrity()
    target = ROOT / "probe.json"
    if target.exists():
        raise FileExistsError(target)
    import torch
    from laya.train import items_from_rows, train_model
    runtime = LocalLayaCategorizer(BASE)
    agent = runtime.agent
    rows = read_rows(PREPARED / "train.jsonl")[:64]
    items, skipped = items_from_rows(agent.tok, rows, MAX_LEN, HEAD_MAX_LEN)
    if skipped:
        raise ValueError(skipped)
    start = time.monotonic()
    losses = train_model(agent.model, agent.tok, items, train_config(1), agent.device, MAX_LEN, HEAD_MAX_LEN)
    torch.mps.synchronize()
    seconds = time.monotonic() - start
    report = {"rows": len(rows), "decisions": len(items), "microbatches": 96,
              "optimizer_updates": 6, "seconds": seconds, "losses": losses,
              "projected_epoch_seconds": seconds * 6231 / len(items),
              "mps_allocated_bytes": torch.mps.current_allocated_memory(),
              "mps_driver_bytes": torch.mps.driver_allocated_memory(),
              "config": asdict(train_config(1)), "versions": versions(),
              "device": str(next(agent.model.parameters()).device),
              "continued_into_full_training": False, "probe_weights_saved": False}
    write_json(target, report)
    write_json(PUBLIC / "probe.json", report)
    print(json.dumps(report), flush=True)


def save_fp32(agent, destination):
    from safetensors.torch import save_file
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    # Match the measured runtime exactly; this complete fp32 package still fits
    # the decimal 3 GB artifact limit. Keep at most the current best checkpoint.
    tensors = {k: v.detach().cpu().contiguous() for k, v in agent.model.state_dict().items()}
    save_file(tensors, str(destination / "model.safetensors"))
    del tensors
    agent.model.encoder.config.save_pretrained(destination / "encoder")
    agent.tok.save_pretrained(destination / "tokenizer")
    cfg = dict(agent.cfg, max_len=MAX_LEN, head_max_len=HEAD_MAX_LEN,
               temperature=[1.0, 1.0, 1.0], temperature_by_options={}, model_name="groundkeeper-laya-v1")
    write_json(destination / "rl_agent_config.json", cfg)


def selection_key(report):
    metrics = report["metrics"]
    return (metrics["macro_f1_supported_categories"], metrics["joint_accuracy"],
            -report["invalid_outputs"], -report["epoch"])


class EarlyStop(Exception):
    pass


def train():
    integrity = check_integrity()
    cfg = json.loads(CONFIG.read_text())
    for source, digest in cfg["code_hashes"].items():
        if sha256(source) != digest:
            raise ValueError(f"Code changed after training configuration froze: {source}")
    if cfg["epochs"] < 1 or cfg["epochs"] > 4 or cfg["loss"] != "soft-ce":
        raise ValueError("Unexpected finite training config")
    if (ROOT / "training-started.json").exists():
        raise FileExistsError("Training already started; do not duplicate or overwrite")
    if not (ROOT / "baseline.json").exists() or not (ROOT / "probe.json").exists():
        raise ValueError("Baseline and compatibility probe required")
    write_json(ROOT / "training-started.json", {"pid": os.getpid(), "unix": time.time(), "config_sha256": sha256(CONFIG)})
    import torch
    from laya.train import items_from_rows, train_model, optimizer_updates
    runtime = LocalLayaCategorizer(BASE)
    agent = runtime.agent
    items, skipped = items_from_rows(agent.tok, read_rows(PREPARED / "train.jsonl"), MAX_LEN, HEAD_MAX_LEN)
    if skipped or len(items) != 6231:
        raise ValueError(skipped)
    settings = train_config(cfg["epochs"])
    if json.loads(json.dumps(asdict(settings))) != cfg["train_config"]:
        raise ValueError("Frozen hyperparameters differ")
    rows = read_rows(SOURCE / "valid_records.jsonl")
    history = []
    best = None
    stale = 0
    start = time.monotonic()
    print(json.dumps({"training_decisions": len(items), "optimizer_updates": optimizer_updates(len(items), 2, 16, settings.epochs),
                      "start_from_original": True, "config": asdict(settings)}), flush=True)
    def on_epoch_end(epoch, loss):
        nonlocal best, stale
        epoch += 1
        report = score(agent, rows, ROOT / "training" / f"validation-epoch-{epoch}")
        report.update(epoch=epoch, mean_training_loss=loss)
        write_json(ROOT / "training" / f"validation-epoch-{epoch}.json", report)
        write_json(PUBLIC / f"validation-epoch-{epoch}.json", report)
        history.append(report)
        if best is None or selection_key(report) > selection_key(best):
            checkpoint = ROOT / "training" / f"checkpoint-epoch-{epoch}"
            save_fp32(agent, checkpoint)
            previous = best
            best = {**report, "checkpoint": str(checkpoint), "weights_sha256": sha256(checkpoint / "model.safetensors")}
            write_json(ROOT / "selection.json", best)
            if previous:
                # Old best artifacts are disposable and never include original/Qwen files.
                shutil.rmtree(previous["checkpoint"])
            stale = 0
        else:
            stale += 1
        write_json(ROOT / "status.json", {"status": "training", "completed_epoch": epoch, "best_epoch": best["epoch"],
                                          "elapsed_seconds": time.monotonic() - start, "stale_epochs": stale})
        if stale >= cfg["early_stop_patience"]:
            raise EarlyStop("No validation improvement for the configured patience")
        agent.model.train()
    stop = "epoch_limit"
    try:
        train_model(agent.model, agent.tok, items, settings, agent.device, MAX_LEN, HEAD_MAX_LEN, on_epoch_end)
    except EarlyStop as error:
        stop = str(error)
    report = {"status": "trained", "elapsed_seconds": time.monotonic() - start, "stop_reason": stop,
              "completed_epochs": len(history), "selected_epoch": best["epoch"],
              "config": cfg, "versions": versions(), "sealed_test_read": False,
              "original_checkpoint_preserved": manifest(ORIGINAL) == integrity["original_files"]}
    write_json(ROOT / "training_report.json", report)
    write_json(PUBLIC / "training_report.json", report)
    write_json(ROOT / "status.json", report)
    print(json.dumps({"status": "trained", "selected_epoch": best["epoch"], "seconds": report["elapsed_seconds"]}), flush=True)


def package():
    check_integrity()
    selection = json.loads((ROOT / "selection.json").read_text())
    checkpoint = Path(selection["checkpoint"])
    if sha256(checkpoint / "model.safetensors") != selection["weights_sha256"]:
        raise ValueError("Selected checkpoint changed")
    destination = ROOT / "package"
    if destination.exists():
        raise FileExistsError(destination)
    shutil.copytree(checkpoint, destination)
    (destination / "questions.json").write_text(json.dumps(QUESTIONS, indent=2))
    for source in ("groundkeeper/laya_runtime.py", "groundkeeper/policy.py", "groundkeeper/__init__.py"):
        path = destination / source
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, path)
    for source in ("experiments/finetune/LABELING_POLICY.md", "experiments/finetune/v2/POLICY_ADDITIONS.md"):
        shutil.copyfile(source, destination / Path(source).name)
    files = manifest(destination)
    # Reload the packaged runtime code and saved weights. Evaluate validation only.
    import importlib.util
    import sys
    package_name = "groundkeeper_laya_package"
    package_spec = importlib.util.spec_from_file_location(package_name, destination / "groundkeeper/__init__.py",
                                                       submodule_search_locations=[str(destination / "groundkeeper")])
    package_module = importlib.util.module_from_spec(package_spec)
    sys.modules[package_name] = package_module
    package_spec.loader.exec_module(package_module)
    code = destination / "groundkeeper/laya_runtime.py"
    spec = importlib.util.spec_from_file_location(package_name + ".laya_runtime", code)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    runtime = module.LocalLayaCategorizer(destination)
    reload_report = score(runtime.agent, read_rows(SOURCE / "valid_records.jsonl"), ROOT / "package-validation")
    expected = read_rows(ROOT / "training" / f"validation-epoch-{selection['epoch']}.jsonl")
    actual = read_rows(ROOT / "package-validation.jsonl")
    mismatches = sum(a["prediction"] != b["prediction"] for a, b in zip(expected, actual))
    if len(expected) != len(actual) or mismatches:
        raise ValueError(f"Runtime reload predictions changed: {mismatches}")
    report = {"selected_epoch": selection["epoch"], "files": files,
              "package_bytes_before_manifest": sum(f["bytes"] for f in files.values()),
              "reload_mismatches": mismatches, "reload_validation_n": len(actual),
              "metrics": reload_report["metrics"], "model_weights_sha256": selection["weights_sha256"],
              "real_data": False, "application_review_required": True, "sealed_test_read": False,
              "runtime_code_loaded_from_package": str(code), "versions": versions()}
    write_json(destination / "manifest.json", report)
    report["package_bytes"] = sum(p.stat().st_size for p in destination.rglob("*") if p.is_file())
    if report["package_bytes"] >= 3_000_000_000:
        raise ValueError("Package exceeds size budget")
    write_json(ROOT / "package_report.json", report)
    write_json(PUBLIC / "package_report.json", report)
    write_json(PUBLIC / "package-validation.json", reload_report)
    write_json(ROOT / "status.json", {"status": "complete", "selected_epoch": selection["epoch"],
                                      "package_bytes": report["package_bytes"], "sealed_test_read": False})
    print(json.dumps({"status": "complete", "package_bytes": report["package_bytes"], "reload_mismatches": mismatches}), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("prepare", "baseline", "probe", "train", "package"))
    args = parser.parse_args()
    globals()[args.phase]()


if __name__ == "__main__":
    main()
