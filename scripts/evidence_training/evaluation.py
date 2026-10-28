"""Paired, merchant-family-clustered final comparisons; no selection logic."""

import random


def type_category(answer):
    return answer["type"], answer["category"]


def macro_f1(gold, predictions, categories):
    scores = []
    for category in categories:
        tp = sum(
            a["category"] == category and b["category"] == category
            for a, b in zip(gold, predictions)
        )
        fp = sum(
            a["category"] != category and b["category"] == category
            for a, b in zip(gold, predictions)
        )
        fn = sum(
            a["category"] == category and b["category"] != category
            for a, b in zip(gold, predictions)
        )
        scores.append(2 * tp / (2 * tp + fp + fn) if 2 * tp + fp + fn else 0)
    return sum(scores) / len(scores)


def paired_report(rows, candidate, baseline, *, samples=500, seed=20261028):
    from .pipeline import digest, variants

    def index(records):
        result = {(r["id"], r["variant"]): r for r in records}
        if len(result) != len(records):
            raise ValueError("Duplicate prediction identity")
        return result

    current, previous = index(candidate), index(baseline)
    examples = []
    for row in rows:
        for variant, inputs, answer in variants(row):
            key = (row["id"], variant)
            for predictions in (current, previous):
                record = predictions[key]
                if record["input_sha256"] != digest(inputs) or record["split"] != row["split"]:
                    raise ValueError("Paired report inputs or splits are not identical")
            examples.append(
                {
                    "id": row["id"],
                    "source": row["source"],
                    "merchant_family": row["merchant_family"],
                    "variant": variant,
                    "context_status": "matched"
                    if "merchant_context" in inputs
                    else "no_context_fallback",
                    "other_reason": row["provenance"].get("other_reason", "unannotated"),
                    "gold": answer,
                    "candidate": current[key]["prediction"],
                    "baseline": previous[key]["prediction"],
                    "candidate_invalid": bool(current[key]["error"]),
                    "baseline_invalid": bool(previous[key]["error"]),
                }
            )
    if len(examples) != len(current) or len(examples) != len(previous):
        raise ValueError("Paired report prediction membership mismatch")

    cohorts = {"all": examples}
    for source in sorted({r["source"] for r in rows}):
        cohorts["source:" + source] = [e for e in examples if e["source"] == source]
        for variant in sorted({e["variant"] for e in examples}):
            selected = [e for e in examples if e["source"] == source and e["variant"] == variant]
            if selected:
                cohorts[f"source:{source}/variant:{variant}"] = selected
    for variant in sorted({e["variant"] for e in examples}):
        cohorts["variant:" + variant] = [e for e in examples if e["variant"] == variant]
    for status in ("matched", "no_context_fallback"):
        selected = [
            e for e in examples if e["variant"] == "with_context" and e["context_status"] == status
        ]
        if selected:
            cohorts["production-context:" + status] = selected
    report = {}
    for name, cohort in cohorts.items():
        categories = sorted({e["gold"]["category"] for e in cohort}, key=str)

        def scores(items, field):
            gold, predictions = [e["gold"] for e in items], [e[field] for e in items]
            return (
                sum(type_category(a) == type_category(b) for a, b in zip(gold, predictions))
                / len(items),
                macro_f1(gold, predictions, categories),
            )

        a, b = scores(cohort, "candidate"), scores(cohort, "baseline")
        clusters = {}
        for e in cohort:
            clusters.setdefault(e["merchant_family"], []).append(e)
        keys = sorted(clusters)
        rng = random.Random(seed)
        distributions = [[], []]
        for _ in range(samples):
            sampled = [e for key in rng.choices(keys, k=len(keys)) for e in clusters[key]]
            left, right = scores(sampled, "candidate"), scores(sampled, "baseline")
            for k in (0, 1):
                distributions[k].append(left[k] - right[k])
        intervals = []
        for distribution in distributions:
            distribution.sort()
            intervals.append(
                [distribution[int(0.025 * (samples - 1))], distribution[int(0.975 * (samples - 1))]]
            )
        report[name] = {
            "n_rows": len({e["id"] for e in cohort}),
            "n_families": len(clusters),
            "n_views": len(cohort),
            "candidate_type_category_accuracy": a[0],
            "baseline_type_category_accuracy": b[0],
            "type_category_delta": a[0] - b[0],
            "type_category_delta_95ci": intervals[0],
            "candidate_macro_f1": a[1],
            "baseline_macro_f1": b[1],
            "macro_f1_delta": a[1] - b[1],
            "macro_f1_delta_95ci": intervals[1],
            "observed_regression": a[0] < b[0] or a[1] < b[1],
            "regression_95ci": intervals[0][1] < 0 or intervals[1][1] < 0,
            "candidate_invalid_outputs": sum(e["candidate_invalid"] for e in cohort),
            "baseline_invalid_outputs": sum(e["baseline_invalid"] for e in cohort),
            "per_category": {
                str(category) if category is not None else "__none__": {
                    "support": sum(e["gold"]["category"] == category for e in cohort),
                    "candidate_recall": sum(
                        e["gold"]["category"] == category and e["candidate"]["category"] == category
                        for e in cohort
                    )
                    / sum(e["gold"]["category"] == category for e in cohort),
                    "baseline_recall": sum(
                        e["gold"]["category"] == category and e["baseline"]["category"] == category
                        for e in cohort
                    )
                    / sum(e["gold"]["category"] == category for e in cohort),
                }
                for category in categories
            },
            "other_annotation_reasons": {
                reason: sum(
                    e["gold"]["category"] == "other" and str(e["other_reason"]) == reason
                    for e in cohort
                )
                for reason in sorted(
                    {str(e["other_reason"]) for e in cohort if e["gold"]["category"] == "other"}
                )
            },
        }
        for field in ("candidate", "baseline"):
            specific = [
                e
                for e in cohort
                if e[field]["type"] != "unknown"
                and e[field]["category"] != "other"
                and not e[field + "_invalid"]
            ]
            errors = sum(type_category(e["gold"]) != type_category(e[field]) for e in specific)
            report[name][field + "_specific_suggestion_coverage"] = len(specific) / len(cohort)
            report[name][field + "_specific_suggestion_errors"] = errors
            report[name][field + "_specific_suggestion_error_rate"] = (
                errors / len(specific) if specific else None
            )
    return {
        "cohorts": report,
        "bootstrap_samples": samples,
        "primary_cohort": "variant:with_context",
        "secondary_cohort": "all: includes synthetic web-context dropout views",
        "confidence_method": "paired percentile bootstrap clustered by merchant_family; supported gold categories fixed within cohort",
        "confidence_note": "Intervals quantify this sampled corpus; they do not establish human-gold label validity or deployment safety.",
    }
