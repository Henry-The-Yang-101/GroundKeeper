"""Run one labeled receipt regression case against actual selected providers.

Expected answers are used only for scoring, never passed to inference. Original
user images and private description overrides should stay in an ignored folder.
"""
import argparse
import hashlib
import json
from pathlib import Path

from groundkeeper.receipts import context_from_text


def variants(case, description=None):
    baseline = dict(case["input"])
    if description is not None:
        baseline["description"] = description.strip()
    context = context_from_text(case["receipt_ocr"]["text"])
    if context is None:
        raise ValueError("Receipt case has no usable OCR evidence")
    return [("description_only", baseline), ("ocr_context", {**baseline, "receipt_context": context})]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", type=Path)
    parser.add_argument("--provider", choices=["qwen", "apple"], required=True)
    parser.add_argument("--package", type=Path)
    parser.add_argument("--shortcut", default="GK Categorize Cloud")
    parser.add_argument("--description-file", type=Path, help="Ignored private file containing the exact transaction description")
    parser.add_argument("--work", type=Path, default=Path(".local/receipts/user-cases"))
    parser.add_argument("--require-correct", action="store_true", help="Fail the integration check if either variant misses the user label")
    args = parser.parse_args()
    from groundkeeper.worker import Worker, POLICY_VERSION
    case = json.loads(args.case.read_text())
    description = args.description_file.read_text() if args.description_file else None
    target = args.work / (case["id"] + "-" + args.provider + ".json")
    if target.exists():
        raise FileExistsError("Keep previous observations; choose a new --work directory for another run")
    worker = Worker()
    def request(operation, **kwargs):
        return {"protocol_version": 1, "request_id": case["id"], "operation": operation, **kwargs}
    try:
        if args.provider == "apple":
            prepared = worker.handle(request("prepare_shortcut", shortcut_name=args.shortcut))
        else:
            if args.package is None:
                parser.error("--package is required for Qwen")
            prepared = worker.handle(request("prepare_model"), package_root=args.package.resolve())
        if prepared["status"] != "succeeded":
            raise RuntimeError(prepared)
        identity = prepared["result"]["model"]
        results = []
        for name, inputs in variants(case, description):
            response = worker.handle(request("classify", input=inputs, model_manifest_sha256=identity["manifest_sha256"],
                policy_version=POLICY_VERSION, job_id=case["id"], part_id=case["id"], transaction_revision=1))
            decision = response.get("result", {}).get("decision")
            results.append({"variant": name, "status": response["status"], "decision": decision, "error": response.get("error"),
                "input_sha256": hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest(),
                "matches_expected": decision is not None and all(decision.get(k) == v for k, v in case["expected"].items())})
            if response.get("error", {}).get("code") == "shortcut_rate_limited":
                break
        report = {"case_id": case["id"], "case_sha256": hashlib.sha256(args.case.read_bytes()).hexdigest(),
                  "expected": case["expected"], "model": identity, "private_description_override": description is not None,
                  "ocr_producer": case["receipt_ocr"]["producer"], "privacy": "Receipt and input text omitted; identifying fields redacted from committed fixture",
                  "results": results, "scope": "One user-labeled case; not an accuracy-rate estimate"}
        args.work.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2), flush=True)
        if args.require_correct and (len(results) != 2 or not all(r["matches_expected"] for r in results)):
            raise SystemExit(1)
    finally:
        worker.release()


if __name__ == "__main__":
    main()
