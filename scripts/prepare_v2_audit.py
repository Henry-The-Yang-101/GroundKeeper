"""Select 150 new retained training/validation labels for blind second review."""

import hashlib
from collections import Counter

from scripts.common_io import read_rows, write_json
from scripts.prepare_v2_training import OUT, write_rows


def main():
    out = OUT / "new-audit"
    if out.exists():
        raise FileExistsError("Do not replace already dispatched blind packets")
    rows = [
        r
        for split in ("train", "valid")
        for r in read_rows(OUT / f"draft/{split}_records.jsonl")
        if not r.get("legacy_training")
    ]
    rows.sort(key=lambda r: hashlib.sha256(("v2-audit:" + r["id"]).encode()).hexdigest())
    selected, ids = [], set()

    def take(predicate, n):
        matches = [r for r in rows if r["id"] not in ids and predicate(r)][:n]
        selected.extend(matches)
        ids.update(r["id"] for r in matches)

    # Each nonexpense boundary and the known sparse expense categories get an
    # independent check; remainder emphasizes ambiguity and public-source rows.
    for typ in (
        "income",
        "refund",
        "transfer",
        "card_payment",
        "loan_principal",
        "cash_movement",
        "balance_adjustment",
        "unknown",
    ):
        take(lambda r: r["answer"]["type"] == typ, 8)
    for cat in ("gifts", "taxes", "financial", "other", "utilities", "medical", "housing"):
        take(lambda r: r["answer"]["category"] == cat, 8)
    take(lambda r: r["input"]["currency"] == "CAD", 10)
    take(lambda r: r["origin"] == "public_synthetic", 150 - len(selected))
    take(lambda r: True, 150 - len(selected))
    if len(selected) != 150:
        raise ValueError("Not enough retained new examples for the audit")
    selected.sort(key=lambda r: hashlib.sha256(("blind-order:" + r["id"]).encode()).hexdigest())
    out.mkdir(parents=True)
    for offset in range(0, 150, 25):
        write_rows(
            out / f"packet_{offset // 25:02d}.jsonl",
            [{"id": r["id"], "input": r["input"]} for r in selected[offset : offset + 25]],
        )
    write_json(
        out / "selection.json",
        {
            "ids": [r["id"] for r in selected],
            "count": 150,
            "test_accessed": False,
            "labels_hidden_from_auditors": True,
            "types": dict(Counter(r["answer"]["type"] for r in selected)),
            "categories": dict(Counter(r["answer"]["category"] or "__none__" for r in selected)),
        },
    )
    print("Prepared six blind 25-row audit packets. Parent adjudication is required.")


if __name__ == "__main__":
    main()
