"""Frozen real-description DDGS collection and production Qwen comparisons.

Uses an existing public diagnostic, not synthetic or sealed-test records.
References are pre-existing AI judgments, never claimed to be human gold labels.
"""
import argparse
import hashlib
import json
import math
from collections import Counter
from pathlib import Path
import statistics
import time


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line]


def frozen(source):
    manifest = json.loads((source / "manifest.json").read_text())
    if manifest["reference_status"] != "frozen_before_model_inference" or manifest["training_allowed"]:
        raise ValueError("Expected an already-frozen evaluation-only diagnostic")
    for filename, key in (("sample.jsonl", "sample_sha256"), ("reference.jsonl", "reference_sha256")):
        if digest(source / filename) != manifest[key]:
            raise ValueError("Frozen diagnostic changed")
    sample, reference = rows(source / "sample.jsonl"), rows(source / "reference.jsonl")
    if [r["id"] for r in sample] != [r["id"] for r in reference]:
        raise ValueError("Reference IDs do not match sample")
    return manifest, sample, reference


def collect(args):
    from groundkeeper.merchant_search import MerchantSearch
    manifest, sample, _ = frozen(args.source)
    projected = rows(args.queries)
    if [r["id"] for r in sample] != [r["id"] for r in projected]:
        raise ValueError("Query projections do not match the frozen rows")
    search, cache, stopped = MerchantSearch(), {}, None
    attempted = matched = 0
    started = time.monotonic()
    with args.output.open("x") as output:
        output.write(json.dumps({"record_type": "manifest", "sample_sha256": manifest["sample_sha256"],
            "queries_sha256": digest(args.queries), "query_builder": "GroundKeeperCore.MerchantSearchQuery.make",
            "search_module_sha256": digest("groundkeeper/merchant_search.py"), "locality": "", "region": "ca-en",
            "gap_after_completion_seconds": 10.5, "max_results": 5, "engine": "duckduckgo", "synthetic_rows": 0}) + "\n")
        for index, row in enumerate(projected):
            query = row.get("query")
            key = tuple(query[k].lower() for k in ("merchant", "locality")) if query else None
            elapsed = 0.0
            cached = False
            if query is None:
                evidence = {"outcome": "unsafe_query", "context": None}
            elif key in cache:
                evidence = cache[key]; cached = True
            elif stopped:
                evidence = {"outcome": "backoff", "context": None}
            else:
                before = time.monotonic()
                evidence = search.search(query["merchant"], query["locality"])
                elapsed = time.monotonic() - before
                attempted += 1
                if evidence["outcome"] == "blocked":
                    stopped = "captcha_or_provider_block"
                elif evidence["outcome"] == "unavailable":
                    # Mirror the app's one-minute failure backoff without stalling
                    # the benchmark: remaining rows use baseline input for this run.
                    stopped = "provider_unavailable"
                else:
                    cache[key] = evidence
            matched += int(evidence.get("context") is not None)
            output.write(json.dumps({"id": row["id"], "query": query, "cached": cached,
                "lookup_wall_seconds_including_queue_wait": elapsed, **evidence}, ensure_ascii=False) + "\n")
            output.flush()
            print(json.dumps({"completed": index + 1, "total": len(sample), "attempted": attempted,
                "matched_rows": matched, "outcome": evidence["outcome"], "searches_stopped": stopped}), flush=True)
        output.write(json.dumps({"record_type": "summary", "attempted": attempted, "matched_rows": matched,
            "stop_reason": stopped, "wall_seconds": time.monotonic() - started}) + "\n")


def predict(args):
    from groundkeeper.worker import Worker, POLICY_VERSION
    from groundkeeper.policy import validate_input
    manifest, sample, _ = frozen(args.source)
    contexts = {}
    if args.evidence:
        contexts = {r["id"]: r for r in rows(args.evidence) if "id" in r}
        if set(contexts) != {r["id"] for r in sample}:
            raise ValueError("Evidence must cover every original row, including failures")
    worker = Worker()
    def call(operation, **fields):
        value = worker.handle({"protocol_version": 1, "request_id": "real-benchmark", "operation": operation, **fields}, package_root=args.package)
        if value["status"] != "succeeded":
            raise RuntimeError(value["error"]["code"])
        return value["result"]
    model = call("prepare_model")["model"]
    def infer(row):
        inputs = dict(row["input"])
        context = contexts.get(row["id"], {}).get("context")
        if context is not None:
            inputs["merchant_context"] = context
        validate_input(inputs)
        result = call("classify", input=inputs, policy_version=POLICY_VERSION,
            model_manifest_sha256=model["manifest_sha256"], job_id=row["id"], part_id=row["id"], transaction_revision=1)
        return result, inputs
    try:
        # Warm up using the first actual record; never inject a fabricated row.
        infer(sample[0])
        with args.output.open("x") as output:
            output.write(json.dumps({"record_type": "manifest", "model": model, "sample_sha256": manifest["sample_sha256"],
                "reference_sha256": manifest["reference_sha256"], "evidence_sha256": digest(args.evidence) if args.evidence else None,
                "mode": "enriched" if args.evidence else "baseline", "warmup": "first_real_row_excluded_from_timing",
                "human_labels": 0, "synthetic_rows": 0, "prompt_version": worker.manifest.get("prompt_version", "v1"),
                "adapter_directory": worker.manifest.get("adapter_directory"), "worker_sha256": digest("groundkeeper/worker.py")}) + "\n")
            for index, row in enumerate(sample):
                started = time.perf_counter()
                result, inputs = infer(row)
                output.write(json.dumps({"id": row["id"], "decision": result["decision"],
                    "seconds": time.perf_counter() - started, "web_context_used": "merchant_context" in inputs,
                    "input_sha256": hashlib.sha256(json.dumps(inputs, sort_keys=True, ensure_ascii=False).encode()).hexdigest()}) + "\n")
                output.flush()
                if (index + 1) % 10 == 0:
                    print(json.dumps({"completed": index + 1, "total": len(sample), "model": model["model_id"],
                        "mode": "enriched" if args.evidence else "baseline"}), flush=True)
    finally:
        call("release_model")


def metrics(reference, predictions):
    """Agreement with frozen judgments; these references are not human gold."""
    from groundkeeper.policy import validate_answer
    if len(reference) != len(predictions) or not reference:
        raise ValueError("Expected nonempty, aligned predictions")
    for expected, actual in zip(reference, predictions):
        if expected["id"] != actual["id"]:
            raise ValueError("Prediction order or IDs changed")
        validate_answer(actual["decision"])
    def hits(fields):
        return sum(all(r["answer"][k] == p["decision"][k] for k in fields)
                   for r, p in zip(reference, predictions))
    seconds = sorted(p["seconds"] for p in predictions)
    return {"n": len(reference), "category_agreement": hits(("category",)),
        "type_agreement": hits(("type",)), "type_and_category_agreement": hits(("type", "category")),
        "full_decision_agreement": hits(("type", "category", "review")),
        "review_required": sum(p["decision"]["review"] for p in predictions),
        "context_rows": sum(p["web_context_used"] for p in predictions),
        "model_seconds_median": statistics.median(seconds),
        "model_seconds_p95": seconds[math.ceil(.95 * len(seconds)) - 1],
        "model_seconds_mean": statistics.mean(seconds)}


def paired(reference, baseline, enriched):
    metrics(reference, baseline); metrics(reference, enriched)
    categories = [(r["answer"]["category"], b["decision"]["category"], e["decision"]["category"])
                  for r, b, e in zip(reference, baseline, enriched)]
    return {"n": len(reference),
        "both_agree": sum(b == r and e == r for r, b, e in categories),
        "baseline_only_agrees": sum(b == r and e != r for r, b, e in categories),
        "enriched_only_agrees": sum(b != r and e == r for r, b, e in categories),
        "neither_agrees": sum(b != r and e != r for r, b, e in categories),
        "category_changed": sum(b != e for r, b, e in categories),
        "uncovered_decision_changes": sum(b["decision"] != e["decision"] and not e["web_context_used"]
                                           for b, e in zip(baseline, enriched))}


def score(args):
    manifest, sample, reference = frozen(args.source)
    evidence_file = args.run / "evidence.jsonl"
    evidence = rows(evidence_file)
    searches = [r for r in evidence if "id" in r]
    expected_ids = [r["id"] for r in sample]
    if [r["id"] for r in searches] != expected_ids or evidence[-1].get("record_type") != "summary":
        raise ValueError("Search collection is incomplete")
    report = {"dataset": manifest["dataset"], "sample_sha256": manifest["sample_sha256"],
        "reference_sha256": manifest["reference_sha256"], "evidence_sha256": digest(evidence_file),
        "labels": "frozen_AI_review_not_human_gold", "human_labels": 0, "synthetic_rows": 0,
        "sealed_test_access": False, "n": len(sample),
        "distinct_descriptions": len({r["input"]["description"] for r in sample}),
        "reference_certainty": dict(Counter(r["reference_certainty"] for r in reference)),
        "search": {**evidence[-1], "outcomes": dict(Counter(r["outcome"] for r in searches)),
            "cache_rows": sum(r["cached"] for r in searches)}, "models": {}, "paired": {}, "changed_rows": []}
    report["plan"] = json.loads((args.run / "plan.json").read_text())
    report["environment"] = json.loads((args.run / "environment.json").read_text())
    lookup_seconds = [r["lookup_wall_seconds_including_queue_wait"] for r in searches
                      if not r["cached"] and r["outcome"] not in ("unsafe_query", "backoff")]
    report["search"]["lookup_seconds_median_including_queue_wait"] = statistics.median(lookup_seconds) if lookup_seconds else None
    matched = [i for i, r in enumerate(searches) if r.get("context") is not None]
    high = [i for i, r in enumerate(reference) if r["reference_certainty"] == "high"]
    for model in ("base", "finetuned"):
        configurations = {}
        for mode in ("baseline", "enriched"):
            path = args.run / f"{model}-{mode}.jsonl"
            contents = rows(path)
            identity, predictions = contents[0], contents[1:]
            if model == "base" and identity["adapter_directory"] is not None:
                raise ValueError("The original Qwen comparison must not load an adapter")
            if identity["prompt_version"] != report["plan"]["prompt_version"]:
                raise ValueError("Prompt versions differ between benchmark configurations")
            if identity["sample_sha256"] != manifest["sample_sha256"] or identity["reference_sha256"] != manifest["reference_sha256"]:
                raise ValueError("Predictions used a different frozen sample")
            expected_evidence_hash = digest(evidence_file) if mode == "enriched" else None
            if identity["evidence_sha256"] != expected_evidence_hash:
                raise ValueError("Predictions used different search evidence")
            for original, search, prediction in zip(sample, searches, predictions):
                inputs = dict(original["input"])
                if mode == "enriched" and search.get("context") is not None:
                    inputs["merchant_context"] = search["context"]
                expected_hash = hashlib.sha256(json.dumps(inputs, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
                if prediction["input_sha256"] != expected_hash or prediction["web_context_used"] != ("merchant_context" in inputs):
                    raise ValueError("Original transaction input or context changed")
            result = metrics(reference, predictions)
            result.update(predictions_sha256=digest(path), identity=identity,
                high_certainty=metrics([reference[i] for i in high], [predictions[i] for i in high]) if high else None,
                matched_subset=metrics([reference[i] for i in matched], [predictions[i] for i in matched]) if matched else None)
            report["models"][f"{model}-{mode}"] = result
            configurations[mode] = predictions
        report["paired"][model] = paired(reference, configurations["baseline"], configurations["enriched"])
        for row, ref, baseline, enriched in zip(sample, reference, configurations["baseline"], configurations["enriched"]):
            if baseline["decision"] != enriched["decision"]:
                report["changed_rows"].append({"id": row["id"], "description": row["input"]["description"],
                    "model": model, "reference": ref["answer"], "reference_certainty": ref["reference_certainty"],
                    "baseline": baseline["decision"], "enriched": enriched["decision"],
                    "web_context_used": enriched["web_context_used"]})
    with args.output.open("x") as output:
        json.dump(report, output, indent=2, ensure_ascii=False)
        output.write("\n")
    print(json.dumps({"search": report["search"], "paired": report["paired"], "models": {
        name: {k: v for k, v in result.items() if k not in ("identity", "predictions_sha256", "high_certainty", "matched_subset")}
        for name, result in report["models"].items()}}, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("collect", "predict", "score"))
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--queries", type=Path)
    parser.add_argument("--package", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--run", type=Path)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Refusing to overwrite an existing run")
    if args.operation == "collect":
        if not args.queries:
            parser.error("collect requires production Swift query projections")
        collect(args)
    elif args.operation == "predict":
        if not args.package:
            parser.error("predict requires a verified package")
        predict(args)
    else:
        if not args.run:
            parser.error("score requires the directory containing all four runs")
        score(args)


if __name__ == "__main__":
    main()
