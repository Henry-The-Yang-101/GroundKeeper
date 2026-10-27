"""Evaluate OCR and paired receipt-context predictions on 20 predeclared cases.

No personal ledger or training data is read. Reference categories are explicitly
agent-reviewed policy expectations, not a population accuracy benchmark.
"""

import argparse
import csv
import hashlib
import json
import re
import statistics
import subprocess
import time
from collections import Counter
from pathlib import Path

from groundkeeper.receipts import context_from_text

ROOT = Path(__file__).resolve().parents[1]


def read_rows(path):
    return (
        [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        if path.exists()
        else []
    )


def reference_text(dataset, sample_id):
    return "\n".join(
        ",".join(row[8:])
        for row in csv.reader((dataset / "box" / f"{sample_id}.csv").read_text().splitlines())
    )


def error_rate(reference, actual):
    # Normalized character edit distance, not an order-free bag of words score.
    ref, hyp = " ".join(reference.upper().split()), " ".join(actual.upper().split())
    previous = list(range(len(hyp) + 1))
    for i, char in enumerate(ref, 1):
        current = [i]
        for j, other in enumerate(hyp, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (char != other)))
        previous = current
    return previous[-1] / max(1, len(ref))


def token_f1(reference, actual):
    ref, hyp = [Counter(re.findall(r"[A-Z0-9]+", text.upper())) for text in (reference, actual)]
    overlap = sum((ref & hyp).values())
    return 2 * overlap / max(1, sum(ref.values()) + sum(hyp.values()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["shortcuts-ocr", "prepare", "classify", "report"])
    parser.add_argument("--dataset", type=Path, default=ROOT / ".local/receipts/sroie-100")
    parser.add_argument("--work", type=Path, default=ROOT / ".local/receipts")
    parser.add_argument("--provider", choices=["qwen", "laya", "apple"], default="qwen")
    parser.add_argument("--package", type=Path)
    parser.add_argument("--ocr", choices=["native", "shortcuts"], default="shortcuts")
    parser.add_argument("--shortcut", default="GK Categorize Cloud")
    parser.add_argument(
        "--skip-reference",
        action="store_true",
        help="Only compare description and actual OCR; avoid extra cloud requests",
    )
    parser.add_argument(
        "--publish",
        action="store_true",
        help="Publish aggregate scores and decisions without receipt text or image bytes",
    )
    args = parser.parse_args()
    cases_path = ROOT / "experiments/receipts/cases.json"
    case_definition = json.loads(cases_path.read_text())
    cases = case_definition["cases"]
    args.work.mkdir(parents=True, exist_ok=True)
    ocr_path = args.work / f"{args.ocr}-ocr.jsonl"
    if args.mode == "shortcuts-ocr":
        target = args.work / "shortcuts-ocr.jsonl"
        done = {r["id"] for r in read_rows(target) if r["status"] == "ok"}
        for case in cases:
            if case["id"] in done:
                continue
            source = (args.dataset / "img" / (case["id"] + ".jpg")).resolve()
            output = args.work / f"shortcut-ocr-{case['id']}.txt"
            started = time.monotonic()
            try:
                result = subprocess.run(
                    [
                        "/usr/bin/shortcuts",
                        "run",
                        "GK Receipt OCR",
                        "--input-path",
                        str(source),
                        "--output-path",
                        str(output.resolve()),
                    ],
                    capture_output=True,
                    timeout=35,
                )
                value = {
                    "id": case["id"],
                    "status": "ok" if result.returncode == 0 and output.exists() else "failed",
                    "text": output.read_text() if output.exists() else "",
                    "elapsed_ms": (time.monotonic() - started) * 1000,
                    "producer": "apple_shortcuts",
                    "image_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                }
            except subprocess.TimeoutExpired:
                value = {
                    "id": case["id"],
                    "status": "timeout",
                    "text": "",
                    "elapsed_ms": (time.monotonic() - started) * 1000,
                    "producer": "apple_shortcuts",
                }
            with target.open("a") as file:
                file.write(json.dumps(value) + "\n")
            print(json.dumps({k: v for k, v in value.items() if k != "text"}), flush=True)
            if value["status"] != "ok":
                break  # Resolve helper/permission problems before consuming 20 timeouts.
        return
    ocr = {row["id"]: row for row in read_rows(ocr_path) if row["status"] == "ok"}
    if args.mode == "prepare":
        inbox = args.work / "pilot-inbox"
        (inbox / "assets").mkdir(parents=True, exist_ok=True)
        fixtures = []
        for case in cases:
            sample_id = case["id"]
            if sample_id not in ocr:
                raise ValueError(f"No successful {args.ocr} OCR for {sample_id}")
            key = json.loads((args.dataset / "key" / f"{sample_id}.json").read_text())
            base = {"description": key["company"], "direction": "debit", "currency": None}
            fixtures.append(
                {
                    **case,
                    "input": base,
                    "ocr": ocr[sample_id],
                    "reference_text": reference_text(args.dataset, sample_id),
                }
            )
            payment_id = "pilot-payment-" + sample_id
            payment = {
                "schema_version": 2,
                "event_id": payment_id,
                "source": "wallet_transaction",
                "app": "Wallet",
                "input_shape": "wallet_transaction_fields",
                "captured_at": "2026-10-20T10:00:00-04:00",
                "merchant": key["company"],
                "amount": "CAD 1.00",
                "card_or_pass": "Fictional pilot account",
            }
            # Monetary values are fixtures, not converted Malaysian receipt totals.
            receipt = {
                "schema_version": 3,
                "event_id": "pilot-receipt-" + sample_id,
                "source": "receipt_attachment",
                "captured_at": "2026-10-20T10:01:00-04:00",
                "target": {"source": "wallet_transaction", "app": "Wallet", "event_id": payment_id},
                "receipt": {
                    "ocr": {"producer": ocr[sample_id]["producer"], "text": ocr[sample_id]["text"]},
                    "image": {"path": f"assets/{sample_id}.jpg"},
                },
            }
            for name, value in [("payment", payment), ("receipt", receipt)]:
                (inbox / f"{name}-{sample_id}.json").write_text(json.dumps(value))
            (inbox / "assets" / f"{sample_id}.jpg").write_bytes(
                (args.dataset / "img" / f"{sample_id}.jpg").read_bytes()
            )
        (args.work / f"cases-{args.ocr}.json").write_text(json.dumps(fixtures, indent=2))
        print(f"Prepared {len(fixtures)} cases and isolated payment/receipt fixtures.")
    elif args.mode == "classify":
        from groundkeeper.worker import POLICY_VERSION, Worker

        if args.provider != "apple" and args.package is None:
            raise ValueError("--package is required for a local provider")
        worker = Worker()

        def request(operation, **kwargs):
            return {
                "protocol_version": 1,
                "request_id": "receipt-pilot",
                "operation": operation,
                **kwargs,
            }

        prepared = (
            worker.handle(request("prepare_shortcut", shortcut_name=args.shortcut))
            if args.provider == "apple"
            else worker.handle(request("prepare_model"), package_root=args.package.resolve())
        )
        if prepared["status"] != "succeeded":
            raise RuntimeError(prepared)
        identity = prepared["result"]["model"]
        output = args.work / f"{args.provider}-{args.ocr}-predictions.jsonl"
        prior = read_rows(output)
        case_hash = hashlib.sha256(cases_path.read_bytes()).hexdigest()
        if any(
            row.get("cases_sha256") != case_hash
            or (row.get("result", {}).get("model") and row["result"]["model"] != identity)
            for row in prior
        ):
            raise ValueError(
                "Existing predictions use different cases/model; choose a new --work directory"
            )
        done = {
            (v["id"], v["variant"]): v["input_sha256"] for v in prior if v["status"] == "succeeded"
        }
        for case in json.loads((args.work / f"cases-{args.ocr}.json").read_text()):
            variants = [("description_only", None), ("ocr_context", case["ocr"]["text"])]
            if not args.skip_reference:
                variants.append(("reference_context", case["reference_text"]))
            for variant, text in variants:
                inputs = dict(case["input"])
                if text:
                    context = context_from_text(text)
                    if context:
                        inputs["receipt_context"] = context
                input_hash = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
                if done.get((case["id"], variant)) == input_hash:
                    continue
                value = worker.handle(
                    request(
                        "classify",
                        input=inputs,
                        model_manifest_sha256=identity["manifest_sha256"],
                        policy_version=POLICY_VERSION,
                        job_id=case["id"],
                        part_id=case["id"],
                        transaction_revision=1,
                    )
                )
                value.update(
                    id=case["id"],
                    variant=variant,
                    expected_category=case["category"],
                    input_sha256=input_hash,
                    cases_sha256=hashlib.sha256(cases_path.read_bytes()).hexdigest(),
                )
                with output.open("a") as file:
                    file.write(json.dumps(value) + "\n")
                print(
                    json.dumps(
                        {
                            "id": case["id"],
                            "variant": variant,
                            "status": value["status"],
                            "decision": value.get("result", {}).get("decision"),
                            "error": value.get("error"),
                        }
                    ),
                    flush=True,
                )
                if value.get("error", {}).get("code") == "shortcut_rate_limited":
                    worker.release()
                    return
        worker.release()
    else:
        report = {
            "label_status": case_definition["label_status"],
            "selection": case_definition["selection"],
            "case_count": len(cases),
            "ocr_source": args.ocr,
        }
        records = [ocr[c["id"]] for c in cases if c["id"] in ocr]
        report["ocr"] = {
            "completed": len(records),
            "median_ms": statistics.median([r["elapsed_ms"] for r in records]) if records else None,
            "mean_normalized_character_error_rate": statistics.mean(
                [error_rate(reference_text(args.dataset, r["id"]), r["text"]) for r in records]
            )
            if records
            else None,
            "mean_order_independent_token_f1": statistics.mean(
                [token_f1(reference_text(args.dataset, r["id"]), r["text"]) for r in records]
            )
            if records
            else None,
            "metric_note": "CER is sensitive to reading order, reference annotation errors and whitespace normalization; latency includes CLI launch for Shortcuts.",
        }
        for provider in ("qwen", "laya", "apple"):
            predictions = {
                (r["id"], r["variant"]): r
                for r in read_rows(args.work / f"{provider}-{args.ocr}-predictions.jsonl")
            }
            variants = {}
            for variant in ("description_only", "ocr_context", "reference_context"):
                rows = [
                    predictions[(c["id"], variant)]
                    for c in cases
                    if (c["id"], variant) in predictions
                ]
                if rows:
                    variants[variant] = {
                        "attempted": len(rows),
                        "succeeded": sum(r["status"] == "succeeded" for r in rows),
                        "category_matches": sum(
                            r.get("result", {}).get("decision", {}).get("category")
                            == r["expected_category"]
                            for r in rows
                        ),
                        "joint_matches": sum(
                            r.get("result", {}).get("decision", {}).get("category")
                            == r["expected_category"]
                            and r.get("result", {}).get("decision", {}).get("type") == "expense"
                            for r in rows
                        ),
                    }
            if variants:
                report[provider] = variants
        (args.work / f"report-{args.ocr}.json").write_text(json.dumps(report, indent=2) + "\n")
        if args.publish:
            published = {
                "summary": report,
                "cases_sha256": hashlib.sha256(cases_path.read_bytes()).hexdigest(),
                "models": {},
                "cases": [],
            }
            predictions = {}
            for provider in ("qwen", "laya", "apple"):
                rows = read_rows(args.work / f"{provider}-{args.ocr}-predictions.jsonl")
                predictions[provider] = {(r["id"], r["variant"]): r for r in rows}
                identities = [r["result"]["model"] for r in rows if r["status"] == "succeeded"]
                if identities:
                    assert all(v == identities[0] for v in identities), (
                        "Do not combine different model identities"
                    )
                    published["models"][provider] = identities[0]
            for case in cases:
                row = {"id": case["id"], "expected_category": case["category"], "predictions": {}}
                if case["id"] in ocr:
                    actual = ocr[case["id"]]
                    row["ocr"] = {
                        "elapsed_ms": actual["elapsed_ms"],
                        "image_sha256": actual["image_sha256"],
                        "normalized_character_error_rate": error_rate(
                            reference_text(args.dataset, case["id"]), actual["text"]
                        ),
                        "order_independent_token_f1": token_f1(
                            reference_text(args.dataset, case["id"]), actual["text"]
                        ),
                    }
                for provider, values in predictions.items():
                    row["predictions"][provider] = {
                        variant: {
                            "status": r["status"],
                            "input_sha256": r["input_sha256"],
                            "decision": r.get("result", {}).get("decision"),
                            "error": r.get("error"),
                        }
                        for variant in ("description_only", "ocr_context", "reference_context")
                        if (r := values.get((case["id"], variant))) is not None
                    }
                published["cases"].append(row)
            target = ROOT / "experiments/receipts/results"
            target.mkdir(exist_ok=True)
            (target / f"2026-10-20-{args.ocr}.json").write_text(
                json.dumps(published, indent=2) + "\n"
            )
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
