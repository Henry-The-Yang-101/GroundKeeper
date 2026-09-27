"""Small reproducible M0 Laya probe, not a production accuracy benchmark.

Run with an already-downloaded local checkpoint:
  python research/laya_eval.py /path/to/laya/checkpoint > /tmp/gk-laya-results.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
from importlib.metadata import version
from pathlib import Path

import laya
import torch


# Hand labels were chosen before the follow-up runs. These are merchant-like
# diagnostic strings, not a representative sample of the user's transactions.
CASES = [
    ("PRESTO MOB/<REDACTED>", "transport"),
    ("SQ *BLUE BOTTLE", "dining"),
    ("LOBLAWS #1020", "groceries"),
    ("UBER TRIP", "transport"),
    ("UBER EATS", "dining"),
    ("NETFLIX.COM", "bills"),
    ("AMZN MKTP CA", "shopping"),
    ("AIR CANADA", "travel"),
    ("SEPHORA CANADA", "personal_care"),
    ("STEAM GAMES", "entertainment"),
    ("HYDRO ONE", "bills"),
    ("DOLLARAMA #254", "shopping"),
]

ORIGINAL_QUESTION = {
    "spend_category": {
        "type": "choice",
        "instructions": "Classify the merchant for a personal spending transaction. Choose the most likely spending category.",
        "criteria": {
            "groceries": "Food and household staples from supermarkets or grocery stores",
            "dining": "Restaurants, cafés, takeaway food, and food delivery",
            "transport": "Local transit, rideshare rides, parking, and fuel",
            "shopping": "General retail goods, online marketplaces, and nonfood stores",
            "bills": "Utilities, recurring subscriptions, telecom, and other bills",
            "entertainment": "Games, movies, events, and recreation",
            "health": "Medical care, pharmacies, and health products",
            "travel": "Air travel, hotels, and trips",
            "personal_care": "Beauty, grooming, cosmetics, and salons",
            "other": "Spending that fits no listed category",
        },
    }
}

SHORT_QUESTION = {
    "spend_category": {
        "type": "choice",
        "instructions": "Which spending category best describes this merchant?",
        "criteria": {
            "groceries": "Supermarket or grocery store",
            "dining": "Restaurant, cafe, takeaway, or prepared food delivery",
            "transport": "Local transit, rideshare, parking, or fuel",
            "shopping": "General retail or online marketplace",
            "bills": "Recurring subscription, utility, or telecom bill",
            "entertainment": "Games, movies, events, or recreation",
            "health": "Medical care or pharmacy",
            "travel": "Airline, hotel, or trip",
            "personal_care": "Cosmetics, grooming, beauty, or salon",
            "other": "None of these categories",
        },
    }
}

COARSE_GROUPS = {
    "groceries": "food",
    "dining": "food",
    "transport": "mobility",
    "travel": "mobility",
    "shopping": "retail",
    "personal_care": "retail",
    "bills": "services",
    "entertainment": "services",
    "health": "services",
}
COARSE_QUESTION = {
    "spend_category": {
        "type": "choice",
        "instructions": "Which broad spending group best describes this merchant?",
        "criteria": {
            "food": "Groceries, cafes, restaurants, or food delivery",
            "mobility": "Transit, rides, fuel, airlines, or hotels",
            "retail": "General shopping, cosmetics, grooming, or personal care goods",
            "services": "Bills, subscriptions, medical care, games, or recreation",
        },
    }
}


def minimal_normalize(merchant: str) -> str:
    # Exactly matches the first M0 run, including its deliberately tiny scope.
    return merchant.replace("SQ *", "").replace("AMZN MKTP CA", "Amazon marketplace")


def rows_for(agent, states, question, *, singleton: bool = False, coarse: bool = False):
    if singleton:
        results = [agent.predict(state, question) for state in states]
    else:
        results = agent.predict_batch(states, question, batch_size=12)
    if agent.device.type == "mps":
        torch.mps.synchronize()
    rows = []
    for (merchant, expected), answer in zip(CASES, results):
        answer = answer["answers"]["spend_category"]
        gold = COARSE_GROUPS[expected] if coarse else expected
        rows.append(
            {
                "merchant": merchant,
                "expected": gold,
                "predicted": answer["choice"],
                "correct": answer["choice"] == gold,
                "confidence_entropy": answer.get("confidence"),
                "answer_confidence": answer.get("answer_confidence"),
                "probabilities": answer.get("probabilities"),
            }
        )
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("model_path")
    parser.add_argument("--device", default="mps")
    parser.add_argument(
        "--presto-merchant-file",
        type=Path,
        help="Private, untracked text file containing the exact first merchant input",
    )
    args = parser.parse_args()
    first_merchant = (
        args.presto_merchant_file.read_text().strip()
        if args.presto_merchant_file
        else "PRESTO MOB/<REDACTED>"
    )
    CASES[0] = (first_merchant, "transport")
    agent = laya.load(args.model_path, device=args.device)
    assert agent.device.type == args.device
    assert next(agent.model.parameters()).device.type == args.device

    raw = [m for m, _ in CASES]
    normalized = [minimal_normalize(m) for m in raw]
    no_other = json.loads(json.dumps(ORIGINAL_QUESTION))
    del no_other["spend_category"]["criteria"]["other"]
    reversed_order = json.loads(json.dumps(ORIGINAL_QUESTION))
    original_items = list(reversed_order["spend_category"]["criteria"].items())
    reversed_order["spend_category"]["criteria"] = dict(reversed(original_items))
    runs = [
        ("original_10_raw", raw, ORIGINAL_QUESTION, False, False),
        ("original_10_reversed_options", raw, reversed_order, False, False),
        ("original_10_minimal_normalization", normalized, ORIGINAL_QUESTION, False, False),
        ("original_9_raw", raw, no_other, False, False),
        ("original_9_context", [f"Canadian consumer card purchase at merchant: {m}" for m in raw], no_other, False, False),
        ("short_descriptions_10_raw", raw, SHORT_QUESTION, False, False),
        ("short_descriptions_10_structured", [
            {"transaction": "consumer card purchase", "merchant_raw": m, "merchant_clean": minimal_normalize(m)}
            for m in raw
        ], SHORT_QUESTION, False, False),
        ("coarse_4_raw", raw, COARSE_QUESTION, False, True),
        ("original_10_singleton", raw, ORIGINAL_QUESTION, True, False),
    ]
    output = {
        "laya_version": version("laya"),
        "torch_version": torch.__version__,
        "model_path": args.model_path,
        "device": str(agent.device),
        "parameter_device": str(next(agent.model.parameters()).device),
        "first_case_input_sha256": hashlib.sha256(first_merchant.encode()).hexdigest(),
        "cases": [{"merchant": m, "expected": y} for m, y in CASES],
        "questions": {
            "original_10": ORIGINAL_QUESTION,
            "original_10_reversed_options": reversed_order,
            "original_9": no_other,
            "short_descriptions_10": SHORT_QUESTION,
            "coarse_4": COARSE_QUESTION,
        },
        "runs": [],
    }
    for name, states, question, singleton, coarse in runs:
        rows = rows_for(agent, states, question, singleton=singleton, coarse=coarse)
        output["runs"].append(
            {
                "name": name,
                "states": states,
                "correct": sum(row["correct"] for row in rows),
                "total": len(rows),
                "rows": rows,
            }
        )
    assert agent.device.type == args.device
    assert next(agent.model.parameters()).device.type == args.device
    print(json.dumps(output, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
