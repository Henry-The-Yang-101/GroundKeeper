"""Compare production baseline/enriched prompts using previously captured evidence.

No searches occur here. Run separately for each local model or explicit Shortcut.
The caller chooses fixtures/output paths; private cases belong under .private/.
"""

import argparse
import copy
import hashlib
import json
import time
from pathlib import Path

from groundkeeper.policy import validate_answer, validate_input
from groundkeeper.worker import POLICY_VERSION, Worker


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    provider = parser.add_mutually_exclusive_group(required=True)
    provider.add_argument("--package", type=Path)
    provider.add_argument("--shortcut")
    parser.add_argument("--cases", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    cases = json.loads(args.cases.read_text())
    if not isinstance(cases, list) or not cases:
        parser.error("Expected a nonempty case list")
    for case in cases:
        validate_input(case["input"])
        validate_input({**case["input"], "merchant_context": case["merchant_context"]})
        if "expected" in case:
            validate_answer(case["expected"])
    worker = Worker()

    def call(operation, **fields):
        result = worker.handle(
            {"protocol_version": 1, "request_id": "benchmark", "operation": operation, **fields},
            package_root=args.package,
        )
        if result["status"] != "succeeded":
            raise RuntimeError(result["error"]["code"])
        return result["result"]

    model = call(
        "prepare_model" if args.package else "prepare_shortcut",
        **({} if args.package else {"shortcut_name": args.shortcut}),
    )["model"]
    counts = {
        mode: {"correct": 0, "labeled": 0, "seconds": 0.0} for mode in ("baseline", "enriched")
    }
    try:
        with args.output.open("x") as output:
            output.write(
                json.dumps(
                    {
                        "record_type": "manifest",
                        "model": model,
                        "cases_sha256": hashlib.sha256(args.cases.read_bytes()).hexdigest(),
                        "searches": 0,
                    }
                )
                + "\n"
            )
            for case in cases:
                for mode in counts:
                    inputs = copy.deepcopy(case["input"])
                    inputs.pop("merchant_context", None)
                    if mode == "enriched":
                        inputs["merchant_context"] = case["merchant_context"]
                    started = time.monotonic()
                    result = call(
                        "classify",
                        input=inputs,
                        policy_version=POLICY_VERSION,
                        model_manifest_sha256=model["manifest_sha256"],
                        part_id=case["id"],
                        job_id=mode,
                        transaction_revision=1,
                    )
                    seconds = time.monotonic() - started
                    decision = result["decision"]
                    correct = None
                    if "expected" in case:
                        correct = all(
                            decision[k] == case["expected"][k] for k in ("type", "category")
                        )
                        counts[mode]["labeled"] += 1
                        counts[mode]["correct"] += int(correct)
                    counts[mode]["seconds"] += seconds
                    output.write(
                        json.dumps(
                            {
                                "id": case["id"],
                                "mode": mode,
                                "decision": decision,
                                "correct": correct,
                                "seconds": seconds,
                            }
                        )
                        + "\n"
                    )
                    output.flush()
            output.write(json.dumps({"record_type": "summary", "results": counts}) + "\n")
    finally:
        call("release_model")
    print(json.dumps(counts))


if __name__ == "__main__":
    main()
