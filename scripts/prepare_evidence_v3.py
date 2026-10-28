"""Freeze a bounded public repair cohort and prepare individually reviewed packets.

All source, context, labels and state stay ignored. Historical labels are never
included in reviewer inputs. This command does not train or score a model.
"""

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path

from groundkeeper.policy import validate_answer, validate_input
from scripts.prepare_delaware_labels import family_name

ROOT = Path(__file__).resolve().parents[1]
RUN = ROOT / ".local/finetune/evidence-v3"
POLICY = "groundkeeper-19-v2"


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def read(path):
    return [json.loads(s) for s in Path(path).read_text().splitlines() if s.strip()]


def write_new(path, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x") as stream:
        for row in rows:
            stream.write(canonical(row) + "\n")


def freeze_public():
    destination = RUN / "source"
    if destination.exists():
        raise FileExistsError("Frozen source directory already exists")
    prepared = ROOT / ".local/delaware-labeling-v1/prepared"
    audit = ROOT / ".local/delaware-web-audit-20261023-v1/sample.jsonl"
    exposed = {family_name(r["merchant_family"]) for r in read(audit)}
    registry = defaultdict(set)
    source_paths = [prepared / f"{split}.canonical.jsonl" for split in ("train", "valid", "test")]
    cohorts = {}
    for path in source_paths:
        split = path.name.split(".")[0]
        cohorts[split] = read(path)
        for row in cohorts[split]:
            registry[family_name(row["merchant_family"])].add(split)
    for path in (ROOT / "experiments/finetune/split_manifest.jsonl",
                 ROOT / "experiments/finetune/v2/split_manifest.jsonl"):
        source_paths.append(path)
        for row in read(path):
            split = "valid" if row["split"] in ("validation", "val") else row["split"]
            registry[family_name(row["group"])].add(split)
    conflicts = {group for group, splits in registry.items() if len(splits) != 1}
    selected = []
    requested = {"train": 4000, "valid": 500, "test": 500}
    for split, count in requested.items():
        eligible = [r for r in cohorts[split]
                    if family_name(r["merchant_family"]) not in conflicts
                    and (split != "test" or family_name(r["merchant_family"]) not in exposed)]
        eligible.sort(key=lambda r: hashlib.sha256(("evidence-v3-20261028:" + r["id"]).encode()).hexdigest())
        if len(eligible) < count:
            raise ValueError(f"Only {len(eligible)} eligible {split} rows, need {count}")
        for row in eligible[:count]:
            validate_input(row["input"])
            selected.append({"id": row["id"], "source": "delaware", "split": split,
                             "merchant_family": family_name(row["merchant_family"]),
                             "input": row["input"], "input_sha256": digest(row["input"])})
    # Interleave train and validation for early labeling throughput; final test
    # references are independently repaired but never inspected during selection.
    selected.sort(key=lambda r: hashlib.sha256(("collection-v3:" + r["id"]).encode()).hexdigest())
    write_new(destination / "delaware.jsonl", selected)
    write_new(destination / "historical_families.jsonl",
              ({"merchant_family": k, "split": next(iter(v))} for k, v in sorted(registry.items()) if len(v) == 1))
    write_new(destination / "family_conflicts.jsonl",
              ({"merchant_family": k, "historical_splits": sorted(registry[k])} for k in sorted(conflicts)))
    manifest = {"format": "evidence-v3-source-v1", "count": len(selected),
                "splits": dict(Counter(r["split"] for r in selected)), "seed": "evidence-v3-20261028",
                "policy_version": POLICY, "human_confirmations": 0,
                "source_hashes": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths},
                "audit_sha256": hashlib.sha256(audit.read_bytes()).hexdigest(),
                "excluded_audit_exposed_test_families": len(exposed),
                "excluded_conflicting_historical_families": len(conflicts),
                "input_file_sha256": hashlib.sha256((destination / "delaware.jsonl").read_bytes()).hexdigest(),
                "historical_labels_visible_to_reviewers": False,
                "test_rule": "independent reference repair only; no model predictions until final frozen selection"}
    write_new(destination / "manifest.json", [manifest])
    return manifest


def freeze_private(exact=False):
    destination = ROOT / (".private/qwen-evidence-v3/source-exact" if exact else ".private/qwen-evidence-v3/source")
    if destination.exists():
        raise FileExistsError("Frozen private source directory already exists")
    snapshot = ROOT / (".private/qwen-evidence-v3/snapshot/classifier_inputs.exact.jsonl" if exact
                       else ".private/qwen-evidence-v3/snapshot/classifier_inputs.jsonl")
    registry = {r["merchant_family"]: r["split"] for r in read(RUN / "source/historical_families.jsonl")}
    conflicts = {r["merchant_family"] for r in read(RUN / "source/family_conflicts.jsonl")}
    from scripts.prepare_delaware_labels import family
    rows = []
    for row in read(snapshot):
        validate_input(row["input"])
        group = family(row.get("search_merchant") or row["input"]["description"], set(registry))
        if group in conflicts:
            split = "quarantine"
        elif group in registry:
            split = registry[group]
        else:
            bucket = int(hashlib.sha256(("evidence-v3-private:" + group).encode()).hexdigest()[:8], 16) % 100
            split = "train" if bucket < 80 else "valid" if bucket < 90 else "test"
        rows.append({**row, "source": "personal", "merchant_family": group, "split": split,
                     "input_sha256": digest(row["input"]), "family_status": "provisional_pending_research_audit"})
    write_new(destination / "personal.jsonl", rows)
    manifest = {"format": "evidence-v3-private-source-v1", "count": len(rows),
                "snapshot_input_sha256": hashlib.sha256(snapshot.read_bytes()).hexdigest(),
                "input_file_sha256": hashlib.sha256((destination / "personal.jsonl").read_bytes()).hexdigest(),
                "splits_provisional": dict(Counter(r["split"] for r in rows)),
                "merchant_families_provisional": len({r["merchant_family"] for r in rows}),
                "family_audit_required": True, "human_confirmations": 0,
                "exact_app_inputs": exact,
                "existing_labels_visible_to_reviewers": False}
    write_new(destination / "manifest.json", [manifest])
    return manifest


def packets(source, context_dir, packet_dir, size=20):
    rows = read(source)
    source_by_id = {r["id"]: r for r in rows}
    existing = {r["id"] for path in packet_dir.glob("*/inputs.jsonl") for r in read(path)}
    ready = []
    for path in sorted((context_dir / "records").glob("*.json")):
        context = json.loads(path.read_text())
        ident = context["id"]
        if ident in existing:
            continue
        row = source_by_id[ident]
        if context["input_sha256"] != digest(row["input"]):
            raise ValueError("Context does not match frozen source")
        inputs = dict(row["input"])
        if context["merchant_context"] is not None:
            inputs["merchant_context"] = context["merchant_context"]
        validate_input(inputs)
        safe_query, privacy_reason = context.get("query"), None
        if row.get("source") == "personal":
            from scripts.collect_training_context import private_query_rejection

            privacy_reason = private_query_rejection(safe_query)
            if privacy_reason:
                safe_query = None
        ready.append({**row, "input": inputs, "input_sha256": digest(inputs),
                      "without_context_sha256": digest(row["input"]),
                      "context_outcome": context["outcome"],
                      "safe_query": safe_query, "search_privacy_rejection": privacy_reason,
                      "context_record_sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    created = []
    # Keep test packets separate to avoid reference authors also reviewing train
    # predictions in the same context window.
    for split in ("train", "valid", "test", "quarantine"):
        pending = [r for r in ready if r["split"] == split]
        for offset in range(0, len(pending), size):
            group = pending[offset:offset + size]
            ident = f"{split}-{digest([r['id'] for r in group])[:14]}"
            path = packet_dir / ident
            write_new(path / "inputs.jsonl", group)
            write_new(path / "assignment.json", [{"packet_id": ident, "count": len(group),
                       "model": "gpt-6.1-sol", "reasoning_effort": "high",
                       "internet_search_required": True, "individual_review_required": True,
                       "inputs_sha256": hashlib.sha256((path / "inputs.jsonl").read_bytes()).hexdigest(),
                       "policy_version": POLICY}])
            created.append({"packet": str(path), "count": len(group)})
    return {"created": created, "already_packeted": len(existing), "new_rows": len(ready)}


def validate_packet(path):
    inputs = read(path / "inputs.jsonl")
    labels = read(path / "labels.jsonl")
    if [r["id"] for r in inputs] != [r["id"] for r in labels]:
        raise ValueError("Missing, duplicate, extra, or misordered labels")
    for row, label in zip(inputs, labels):
        if label.get("input_sha256") != row["input_sha256"]:
            raise ValueError("Label input hash mismatch")
        for key in ("answer_with_context", "answer_without_context"):
            validate_answer(label[key])
        if not row["input"].get("merchant_context") and label["answer_with_context"] != label["answer_without_context"]:
            raise ValueError("Identical visible inputs must have identical targets")
        if label.get("reviewer") != {"model": "gpt-6.1-sol", "reasoning_effort": "high"}:
            raise ValueError("Wrong reviewer identity")
        if label.get("label_policy_version") != POLICY:
            raise ValueError("Wrong label policy")
        if not isinstance(label.get("searches"), list) or not label["searches"]:
            raise ValueError("Every row needs actual internet research provenance")
        for search in label["searches"]:
            if search.get("status") == "privacy_blocked":
                if (row.get("source") != "personal" or row.get("safe_query") is not None
                        or search.get("query") is not None or search.get("attempted") is not False
                        or search.get("urls") != [] or not search.get("reason")):
                    raise ValueError("Privacy-blocked research must be explicit and have no attempted query")
                continue
            if not search.get("query") or search.get("status") not in ("results", "no_reliable_match", "unavailable"):
                raise ValueError("Invalid search provenance")
            if not isinstance(search.get("urls"), list):
                raise ValueError("Search URLs must be a list")
            if search["status"] == "results" and not search["urls"]:
                raise ValueError("Successful research requires source URLs")
        if not label.get("merchant_family_proposed") or not label.get("rationale"):
            raise ValueError("Missing identity/rationale")
        if label.get("context_quality") not in ("useful", "irrelevant", "ambiguous", "conflicting", "absent"):
            raise ValueError("Missing context evaluation")
        if label.get("other_reason") not in (None, "insufficient_evidence", "outside_taxonomy", "mixed_or_conflicting"):
            raise ValueError("Invalid Other subtype")
    return {"packet": str(path), "validated": len(labels), "human_confirmations": 0}


def status():
    result = {}
    exact = (ROOT / ".private/qwen-evidence-v3/source-exact/personal.jsonl").exists()
    locations = {
        "delaware": (RUN / "source/delaware.jsonl", RUN / "context/public", RUN / "labeling/public"),
        "personal": (ROOT / (".private/qwen-evidence-v3/source-exact/personal.jsonl" if exact else ".private/qwen-evidence-v3/source/personal.jsonl"),
                     ROOT / (".private/qwen-evidence-v3/context/personal-exact" if exact else ".private/qwen-evidence-v3/context/personal"),
                     ROOT / ".private/qwen-evidence-v3/labeling/personal"),
    }
    for name, (source, context, labeling) in locations.items():
        summary = {"source_rows": len(read(source)) if source.exists() else 0,
                   "context_rows": 0, "context_outcomes": Counter(), "packet_rows": 0,
                   "validated_label_rows": 0, "pending_packets": [], "invalid_packets": []}
        for path in (context / "records").glob("*.json"):
            record = json.loads(path.read_text())
            summary["context_rows"] += 1
            summary["context_outcomes"][record["outcome"]] += 1
        for path in sorted(labeling.glob("*/inputs.jsonl")):
            count = len(read(path))
            summary["packet_rows"] += count
            if not (path.parent / "labels.jsonl").exists():
                summary["pending_packets"].append({"packet": str(path.parent), "count": count})
            else:
                try:
                    summary["validated_label_rows"] += validate_packet(path.parent)["validated"]
                except (ValueError, KeyError, json.JSONDecodeError) as error:
                    summary["invalid_packets"].append({"packet": str(path.parent), "error": type(error).__name__})
        result[name] = summary
    result["new_model_trained"] = (RUN / "training/selection.json").exists()
    result["final_test_report_exists"] = (RUN / "final-report.json").exists()
    result["note"] = "Counts validate structure, not source truth or achieved model quality."
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("freeze-public")
    private = sub.add_parser("freeze-private")
    private.add_argument("--exact", action="store_true")
    sub.add_parser("status")
    packet = sub.add_parser("packets")
    packet.add_argument("--source", type=Path, default=RUN / "source/delaware.jsonl")
    packet.add_argument("--context-dir", type=Path, default=RUN / "context/public")
    packet.add_argument("--packet-dir", type=Path, default=RUN / "labeling/public")
    valid = sub.add_parser("validate-packet")
    valid.add_argument("path", type=Path)
    args = parser.parse_args()
    if args.command == "freeze-public":
        result = freeze_public()
    elif args.command == "freeze-private":
        result = freeze_private(args.exact)
    elif args.command == "status":
        result = status()
    elif args.command == "packets":
        result = packets(args.source, args.context_dir, args.packet_dir)
    else:
        result = validate_packet(args.path)
    print(canonical(result))


if __name__ == "__main__":
    main()
