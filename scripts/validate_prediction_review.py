"""Validate individual researched prediction verdicts against immutable artifacts."""

import argparse
import json
from collections import Counter
from pathlib import Path

from groundkeeper.policy import validate_answer
from scripts.prepare_evidence_v3 import digest, read


def validate(packet):
    packet = Path(packet)
    rows = read(packet / "inputs.jsonl")
    predictions = read(packet / "predictions.jsonl")
    independent = read(packet / "independent.jsonl")
    verdicts = read(packet / "verdicts.jsonl")
    identities = [r["id"] for r in rows]
    if len(set(identities)) != len(identities):
        raise ValueError("Repeated assigned identity")
    if any([r["id"] for r in group] != identities for group in (predictions, independent, verdicts)):
        raise ValueError("Missing, extra, duplicate, or reordered prediction reviews")
    for row, prediction, reference, verdict in zip(rows, predictions, independent, verdicts):
        if row["split"] != "train" or prediction["split"] != "train":
            raise ValueError("Diagnostic correction reviews must be TRAIN-only")
        actual_hash = digest(row["input"])
        if any(r["input_sha256"] != actual_hash for r in (row, prediction, reference, verdict)):
            raise ValueError("Input hash differs from reviewed prediction")
        if prediction["prediction_sha256"] != digest({k: v for k, v in prediction.items() if k != "prediction_sha256"}):
            raise ValueError("Prediction payload was modified")
        for key in ("variant", "model_sha256", "prediction_sha256", "prediction"):
            if verdict[key] != prediction[key]:
                raise ValueError("Verdict does not bind exact prediction/model")
        if verdict["reviewer"] != {"model": "gpt-6.1-sol", "reasoning_effort": "high"}:
            raise ValueError("Wrong reviewer model or effort")
        validate_answer(reference["expected"])
        if verdict["expected"] != reference["expected"]:
            raise ValueError("Expected decision changed after viewing prediction")
        if reference["determinacy"] not in ("determinate", "indeterminate"):
            raise ValueError("Missing determinacy")
        if not reference.get("rationale") or not reference.get("searches"):
            raise ValueError("Individual internet research is required")
        if verdict["searches"] != reference["searches"]:
            raise ValueError("Research provenance changed after prediction view")
        for search in reference["searches"]:
            if not search.get("query") or search.get("status") not in ("results", "no_reliable_match", "unavailable"):
                raise ValueError("Invalid research provenance")
            if not isinstance(search.get("urls"), list) or (search["status"] == "results" and not search["urls"]):
                raise ValueError("Successful research requires actual source URLs")
        same_category = all(reference["expected"][k] == prediction["prediction"][k] for k in ("type", "category"))
        expected_verdict = ("indeterminate" if reference["determinacy"] == "indeterminate" else
                            "correct" if same_category else "incorrect")
        if verdict["verdict"] != expected_verdict:
            raise ValueError("Verdict must compare type/category, not forced review flag")
    return {"count": len(rows), "verdicts": dict(Counter(r["verdict"] for r in verdicts)),
            "split": "train", "training_started": False, "human_confirmations": 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packet", type=Path)
    print(json.dumps(validate(parser.parse_args().packet), sort_keys=True))


if __name__ == "__main__":
    main()
