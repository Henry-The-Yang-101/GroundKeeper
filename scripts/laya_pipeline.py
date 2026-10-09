"""One finite, detached local training job with automatic packaging/reporting."""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from scripts.full_common import write_json

ROOT = Path(".local/laya")
PUBLIC = Path("experiments/laya")


def summarize():
    baseline = json.loads((ROOT / "baseline.json").read_text())
    selected = json.loads((ROOT / "package-validation.json").read_text())
    training = json.loads((ROOT / "training_report.json").read_text())
    package = json.loads((ROOT / "package_report.json").read_text())
    qwen = json.loads(Path(".local/finetune/v2/training/candidate-0/validation-0002080.json").read_text())
    if not baseline["validation_sha256"] == selected["validation_sha256"]:
        raise ValueError("Validation sets differ")
    def percentage(value):
        return f"{100 * value:.1f}%"
    lines = ["# Laya local fine-tuning results", "",
             "Completed on the frozen 2,077-row training / 279-row validation dataset.",
             "All labels are synthetic and AI-reviewed. No sealed test was opened.", "",
             "| Validation metric | Original Laya | Fine-tuned Laya | Existing Qwen v2 |",
             "|---|---:|---:|---:|"]
    for title, key in (("Category accuracy", "category_accuracy"), ("Type accuracy", "type_accuracy"),
                       ("Review agreement", "review_accuracy"), ("Exact three-field accuracy", "joint_accuracy")):
        lines.append("| " + title + " | " + " | ".join(percentage(r["metrics"][key]) for r in (baseline, selected, qwen)) + " |")
    lines.append("| Supported-category macro-F1 | " + " | ".join(f"{r['metrics']['macro_f1_supported_categories']:.3f}" for r in (baseline, selected, qwen)) + " |")
    lines.append("| Invalid final outputs | " + " | ".join(str(r["invalid_outputs"]) for r in (baseline, selected, qwen)) + " |")
    lines += ["", f"Selected epoch: **{package['selected_epoch']}** from {training['completed_epochs']} evaluated epochs.",
              "Selection uses supported-category macro-F1, then exact three-field accuracy, fewer invalid outputs and earlier epoch.",
              f"Training/evaluation runtime: {training['elapsed_seconds'] / 60:.1f} minutes. Stop: {training['stop_reason']}.", "",
              f"Mean warmed single-transaction latency: base {baseline['mean_latency_seconds']:.3f} s; packaged fine-tune {selected['mean_latency_seconds']:.3f} s.",
              f"Fine-tuned package: **{package['package_bytes']:,} bytes**, under 3 GB decimal.",
              f"Packaged runtime/weights reload: {package['reload_validation_n']} validation rows, {package['reload_mismatches']} prediction changes.", "",
              "Base and trained Laya use the same three questions, neutral temperature 1, eager fp32 MPS inference and joint schema decoder.",
              f"Independent-head invalid combinations: base {baseline['raw_invalid_combinations']}/279; trained {selected['raw_invalid_combinations']}/279.",
              "These counts are reported before the constraint; zero final invalid objects does not imply correct decisions.", "",
              "Qwen's saved report is reused on identical inputs/labels; prompts and model runtimes differ. Timing was measured on different runs and is not a controlled speed ratio.",
              "Do not interpret synthetic accuracy, fitted distributions or review=false as real-world calibration. Application suggestions always require review.", "",
              "Local package: `.local/laya/package`. Original checkpoint, discarded probe boundary, Qwen models and all held-out datasets are preserved.",
              "Per-category/source/currency/type metrics, artifacts and package hashes are in the JSON reports. No production deployment or recurring monitor was created.", ""]
    (PUBLIC / "RESULTS.md").write_text("\n".join(lines))


def commit_reports():
    # Do not accidentally commit another chat's staged work in this shared repo.
    staged = subprocess.check_output(["git", "diff", "--cached", "--name-only"], text=True).splitlines()
    if staged:
        return {"status": "skipped", "reason": "Existing staged work preserved"}
    names = ["RESULTS.md", "training_report.json", "package_report.json", "package-validation.json", "pipeline.json"]
    names += [p.name for p in PUBLIC.glob("validation-epoch-*.json")]
    files = [str(PUBLIC / name) for name in names if (PUBLIC / name).exists()]
    subprocess.run(["git", "add", "--", *files], check=True)
    subprocess.run(["git", "diff", "--cached", "--check"], check=True)
    subprocess.run(["git", "commit", "-m", "Record completed local Laya fine-tuning and package verification"], check=True)
    return {"status": "committed", "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()}


def main():
    marker = ROOT / "pipeline.json"
    if marker.exists():
        raise FileExistsError("Pipeline has already started")
    report = {"pid": os.getpid(), "started_unix": time.time(), "status": "running", "phase": "train"}
    write_json(marker, report)
    try:
        for phase, seconds in (("train", 18_900), ("package", 900)):
            report["phase"] = phase
            write_json(marker, report)
            subprocess.run([sys.executable, "-m", "scripts.laya_experiment", phase], check=True, timeout=seconds)
        summarize()
        report.update(status="complete", phase="complete", finished_unix=time.time(), sealed_test_read=False)
        write_json(marker, report)
        write_json(PUBLIC / "pipeline.json", report)
        report["git"] = commit_reports()
        write_json(marker, report)
    except BaseException as error:
        report.update(status="failed", error=repr(error), finished_unix=time.time())
        write_json(marker, report)
        write_json(ROOT / "status.json", report)
        raise


if __name__ == "__main__":
    main()
