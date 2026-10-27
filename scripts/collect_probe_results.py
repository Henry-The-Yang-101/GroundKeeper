"""Snapshot public experiment evidence; never read private or final-test rows."""

import hashlib
import json
from pathlib import Path


def main():
    root = Path(".local/finetune")
    dest = Path("experiments/finetune/results")
    dest.mkdir(exist_ok=True)
    report_names = [
        "text_model_report",
        "compatibility_check",
        "classifier_baseline_report",
        "baseline_strict_report",
        "baseline_report",
        "probe_report",
        "probe-eval_report",
        "merchant_reference_report",
        "package_report",
    ]
    evidence = {}
    for name in report_names:
        source = root / f"{name}.json"
        raw = source.read_bytes()
        json.loads(raw)
        (dest / source.name).write_bytes(raw)
        evidence[source.name] = hashlib.sha256(raw).hexdigest()
    # Keep runtime measurements, excluding unrelated process inventory.
    for name in ["qlora-probe", "probe-validation", "probe-package"]:
        source = root / "runs" / f"{name}.json"
        report = json.loads(source.read_text())
        report.pop("active_processes_before", None)
        (dest / f"{name}_watchdog.json").write_text(json.dumps(report, indent=2) + "\n")
        evidence[f"{name}_watchdog.json"] = hashlib.sha256(source.read_bytes()).hexdigest()
    manifest = root / "package-probe/manifest.json"
    (dest / "package_manifest.json").write_bytes(manifest.read_bytes())
    evidence["package_manifest.json"] = hashlib.sha256(manifest.read_bytes()).hexdigest()
    # Bind these measurements to the code, input manifest and environment lock.
    bound_files = [
        "uv.lock",
        "experiments/finetune/probe_config.json",
        "experiments/finetune/LABELING_POLICY.md",
        "experiments/finetune/split_manifest.jsonl",
        "groundkeeper/policy.py",
        "groundkeeper/runtime.py",
        "groundkeeper/metrics.py",
        "scripts/run_experiment.py",
    ]
    hashes = {p: hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in bound_files}
    probe = json.loads((root / "probe_report.json").read_text())
    seeded = probe.get("numpy_shuffle_seeded", False)
    measured_hash = probe.get("harness_sha256")
    if measured_hash is None:
        measured_hash = hashlib.sha256(
            (dest / "probe_runner_measured.py.txt").read_bytes()
        ).hexdigest()
    summary = {
        "status": "bounded_probe_complete_full_run_awaiting_approval",
        "output_contract": {"type": "expense", "category": "dining", "review": False},
        "confidence_score": None,
        "final_category_test_scored": False,
        "real_reviewed_transactions": 0,
        "measured_probe_numpy_shuffle_seeded": seeded,
        "seed_note": "MLX and NumPy seeds applied."
        if seeded
        else "Measured probe seeded MLX but not NumPy batch order. Future wrapper runs seed both. Archived weights are exact; the measured training trajectory cannot be regenerated from seed alone.",
        "measured_runner_sha256": measured_hash,
        "source_report_sha256": evidence,
        "code_and_input_sha256": hashes,
        "watchdog_note": "Hashes refer to original local reports; process inventories are omitted in snapshots.",
    }
    (dest / "evidence.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"snapshots": len(evidence), "destination": str(dest)}))


if __name__ == "__main__":
    main()
