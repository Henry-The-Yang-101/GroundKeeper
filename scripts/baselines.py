"""Lightweight category baseline plus separate public merchant identity benchmark."""

import csv
import hashlib
import json
from pathlib import Path

from rapidfuzz import fuzz, process
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import make_pipeline

from groundkeeper.merchant import normalize
from groundkeeper.metrics import evaluate

ROOT = Path(".local/finetune")


def read(p):
    return [json.loads(s) for s in p.read_text().splitlines()]


def category():
    train = read(ROOT / "prepared/train_records.jsonl")
    valid = read(ROOT / "prepared/valid_records.jsonl")

    def text(r):
        return json.dumps(r["input"], sort_keys=True)

    def target(r):
        return json.dumps(r["answer"], sort_keys=True)

    model = make_pipeline(
        TfidfVectorizer(analyzer="char_wb", ngram_range=(3, 5), min_df=1, sublinear_tf=True),
        LogisticRegression(C=2, max_iter=500, class_weight="balanced", random_state=20261008),
    )
    model.fit([text(r) for r in train], [target(r) for r in train])
    pred = [json.loads(x) for x in model.predict([text(r) for r in valid])]
    result = evaluate([r["answer"] for r in valid], pred)
    result.update(
        model="char_wb 3-5 TF-IDF + balanced logistic regression, C=2",
        all_merchants_unseen=True,
        confirmed_merchant_pipeline={
            "coverage": 0,
            "reason": "No user-confirmed aliases exist. Public/AI labels are not personal confirmations.",
            "unresolved": len(valid),
        },
    )
    (ROOT / "classifier_baseline_report.json").write_text(json.dumps(result, indent=2))
    print("classifier", json.dumps(result))


def merchants():
    rows = list(csv.DictReader((ROOT / "sources/crossingminds/data.csv").open()))
    print("merchant source rows", len(rows), "fields", list(rows[0]))
    desc = "string"
    name = "merchant"
    unique = {}
    for row in rows:
        unique.setdefault((row[desc], row[name]), row)
    parts = {"train": [], "valid": [], "test": []}
    for row in unique.values():
        k = (
            int(
                hashlib.sha256(
                    ("merchant-reference-v1:" + normalize(row[desc])).encode()
                ).hexdigest(),
                16,
            )
            % 100
        )
        parts["train" if k < 80 else "valid" if k < 90 else "test"].append(row)
    # This is identity reference vocabulary, not category memory/confirmed aliases.
    vocabulary = sorted({r[name] for r in parts["train"]})
    normalized = {normalize(m): m for m in vocabulary}

    def predict(row):
        candidates = process.extract(
            normalize(row[desc]), list(normalized), scorer=fuzz.WRatio, limit=2
        )
        return {
            "truth": row[name],
            "prediction": normalized[candidates[0][0]],
            "score": candidates[0][1],
            "margin": candidates[0][1] - candidates[1][1],
            "seen_merchant": row[name] in vocabulary,
        }

    valid = [predict(r) for r in parts["valid"]]
    test = [predict(r) for r in parts["test"]]

    def stats(rows, t, m):
        selected = [r for r in rows if r["score"] >= t and r["margin"] >= m]
        n = len(selected)
        err = sum(r["truth"] != r["prediction"] for r in selected)
        return {
            "n": len(rows),
            "selected": n,
            "coverage": n / len(rows) if rows else 0,
            "errors": err,
            "error_rate": err / n if n else None,
            "top1_accuracy": sum(r["truth"] == r["prediction"] for r in rows) / len(rows)
            if rows
            else None,
        }

    grid = [
        {"threshold": t, "margin": m, **stats(valid, t, m)}
        for t in [80, 85, 90, 95, 97, 100]
        for m in [0, 5, 10, 15, 20]
    ]
    eligible = [r for r in grid if r["selected"] >= 20 and r["error_rate"] <= 0.01]
    selected = (
        max(eligible, key=lambda r: (r["coverage"], r["threshold"], r["margin"]))
        if eligible
        else {"threshold": 101, "margin": 101}
    )
    t, m = selected["threshold"], selected["margin"]
    report = {
        "source_rows": len(rows),
        "unique_pairs": len(unique),
        "source_sha256": hashlib.sha256(
            (ROOT / "sources/crossingminds/data.csv").read_bytes()
        ).hexdigest(),
        "split_counts": {k: len(v) for k, v in parts.items()},
        "reference_merchant_count": len(vocabulary),
        "selection": selected,
        "validation_grid": grid,
        "test": stats(test, t, m),
        "test_seen": stats([r for r in test if r["seen_merchant"]], t, m),
        "test_unseen": stats([r for r in test if not r["seen_merchant"]], t, m),
        "limitations": "Synthetic author-reviewed merchant identities; closed reference vocabulary for seen subset. Not category training, private confirmation, or real automatic-acceptance calibration. Threshold is not deployed.",
    }
    (ROOT / "merchant_reference_report.json").write_text(json.dumps(report, indent=2))
    print(
        "merchant_reference",
        json.dumps({k: v for k, v in report.items() if k != "validation_grid"}),
    )


if __name__ == "__main__":
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["category", "merchants"])
    a = p.parse_args()
    category() if a.mode == "category" else merchants()
