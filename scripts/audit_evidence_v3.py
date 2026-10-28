"""Audit completed research labels and family leakage; never infer labels.

This makes a reviewable family/split plan under ignored private storage. It does
not accept the dataset or silently change historical split ownership.
"""

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from pathlib import Path

from scripts.prepare_delaware_labels import family_name
from scripts.prepare_evidence_v3 import ROOT, RUN, digest, read, validate_packet, write_new

PRIVATE = ROOT / ".private/qwen-evidence-v3"


class Components:
    def __init__(self):
        self.parents = {}

    def find(self, key):
        self.parents.setdefault(key, key)
        if self.parents[key] != key:
            self.parents[key] = self.find(self.parents[key])
        return self.parents[key]

    def union(self, left, right):
        a, b = self.find(left), self.find(right)
        self.parents[max(a, b)] = min(a, b)


def family_plan(records, historical):
    """Research aliases link source families, never move exposed rows to train."""
    components = Components()
    owners = defaultdict(set)
    for row in historical:
        group = family_name(row["merchant_family"])
        components.find(group)
        owners[group].add(row["split"])
    for row in records:
        original = family_name(row["merchant_family"])
        proposed = family_name(row["label"]["merchant_family_proposed"])
        if not proposed:
            raise ValueError("Empty proposed family")
        components.union(original, proposed)
        owners[original].add(row["split"])
    members = defaultdict(list)
    for group in components.parents:
        members[components.find(group)].append(group)
    decisions = {}
    for root, aliases in members.items():
        splits = set().union(*(owners[a] for a in aliases))
        decisions[root] = {"canonical_family": "family-v3:" + digest(sorted(aliases))[:24],
                           "aliases": sorted(aliases), "historical_splits": sorted(splits),
                           "status": "quarantine_cross_split" if len(splits) != 1 or "quarantine" in splits else "consistent",
                           "split": next(iter(splits)) if len(splits) == 1 else None,
                           "ids": []}
    for row in records:
        decisions[components.find(family_name(row["merchant_family"]))]["ids"].append(row["id"])
    return sorted((r for r in decisions.values() if r["ids"]), key=lambda r: r["canonical_family"])


def collect_completed(packet_roots):
    records, seen, bindings = [], set(), []
    for packet_root in packet_roots:
        for path in sorted(Path(packet_root).glob("*/labels.jsonl")):
            validate_packet(path.parent)
            inputs, labels = read(path.parent / "inputs.jsonl"), read(path)
            bindings.append({"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                             "inputs_sha256": hashlib.sha256((path.parent / "inputs.jsonl").read_bytes()).hexdigest()})
            for source, label in zip(inputs, labels):
                if source["id"] in seen:
                    raise ValueError("Duplicate primary labels across packets")
                seen.add(source["id"])
                records.append({**source, "label": label, "label_path": str(path)})
    return records, bindings


def audit(destination, require_complete=False):
    destination = Path(destination).resolve()
    if not destination.is_relative_to(PRIVATE.resolve()):
        raise ValueError("Audits can contain private merchant identities; use .private/qwen-evidence-v3")
    if destination.exists():
        raise FileExistsError("Preserve prior audit versions")
    sources = [RUN / "source/delaware.jsonl", PRIVATE / "source-exact/personal.jsonl"]
    source_rows = [r for path in sources for r in read(path)]
    expected = {r["id"]: r for r in source_rows}
    if len(expected) != len(source_rows):
        raise ValueError("Source IDs collide")
    records, bindings = collect_completed([RUN / "labeling/public", PRIVATE / "labeling/personal"])
    if set(r["id"] for r in records) - set(expected):
        raise ValueError("Labels include unexpected source IDs")
    for row in records:
        source = expected[row["id"]]
        without = {k: v for k, v in row["input"].items() if k != "merchant_context"}
        if digest(without) != digest(source["input"]) or row["split"] != source["split"]:
            raise ValueError("Packet source/split differs from frozen cohort")
    complete = len(records) == len(expected)
    if require_complete and not complete:
        raise ValueError(f"Only {len(records)}/{len(expected)} individual research labels complete")
    registry = read(RUN / "source/historical_families.jsonl")
    for row in read(RUN / "source/family_conflicts.jsonl"):
        registry.extend({"merchant_family": row["merchant_family"], "split": s} for s in row["historical_splits"])
    plan = family_plan(records, registry)
    cross = [r for r in plan if r["status"] != "consistent"]
    summary = {"expected_rows": len(expected), "reviewed_rows": len(records), "all_rows_reviewed": complete,
               "source_counts": dict(Counter(r["source"] for r in records)),
               "context_quality": dict(Counter(r["label"]["context_quality"] for r in records)),
               "different_paired_targets": sum(r["label"]["answer_with_context"] != r["label"]["answer_without_context"] for r in records),
               "cross_split_components": len(cross), "rows_in_cross_split_components": sum(len(r["ids"]) for r in cross),
               "accepted_for_training": False,
               "next_action": "Independently audit proposed aliases/cross-split components; complete labels; accept exact reviewed version before freeze.",
               "source_hashes": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
    write_new(destination / "summary.json", [summary])
    write_new(destination / "family-plan.jsonl", plan)
    write_new(destination / "label-bindings.jsonl", bindings)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    print(json.dumps(audit(args.destination, args.require_complete), sort_keys=True))


if __name__ == "__main__":
    main()
