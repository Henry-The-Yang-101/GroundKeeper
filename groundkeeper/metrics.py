"""Metrics distinguish semantic suggestions from deployed acceptance."""

from sklearn.metrics import accuracy_score, precision_recall_fscore_support

from .policy import CATEGORIES


def evaluate(gold, predictions, accepted=None):
    if len(gold) != len(predictions) or not gold:
        raise ValueError("Aligned nonempty examples required")
    if accepted is None:
        accepted = [False] * len(gold)
    if len(accepted) != len(gold):
        raise ValueError("Acceptance length mismatch")
    cats = [r["category"] or "__none__" for r in gold]
    out = [r["category"] or "__none__" for r in predictions]
    labels = list(CATEGORIES) + ["__none__"]
    p, r, f, s = precision_recall_fscore_support(cats, out, labels=labels, zero_division=0)
    supported = [i for i, count in enumerate(s) if count]
    joint = [a == b for a, b in zip(gold, predictions)]
    errors = sum(bool(ok) and not hit for ok, hit in zip(accepted, joint))
    n = sum(accepted)
    return {
        "n": len(gold),
        "joint_accuracy": sum(joint) / len(joint),
        "category_accuracy": accuracy_score(cats, out),
        "type_accuracy": accuracy_score(
            [g["type"] for g in gold], [v["type"] for v in predictions]
        ),
        "review_accuracy": accuracy_score(
            [g["review"] for g in gold], [v["review"] for v in predictions]
        ),
        "macro_f1_supported_categories": float(sum(f[i] for i in supported) / len(supported)),
        "macro_f1_all_categories": float(sum(f) / len(f)),
        "per_category": {
            label: {
                "precision": float(p[i]),
                "recall": float(r[i]),
                "f1": float(f[i]),
                "support": int(s[i]),
            }
            for i, label in enumerate(labels)
        },
        "automatic_acceptance_coverage": n / len(gold),
        "automatically_accepted_errors": errors,
        "automatically_accepted_error_rate": errors / n if n else None,
        "acceptance_note": "No real held-out calibration exists; deployed model acceptance remains disabled.",
    }
