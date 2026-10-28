"""Audit complete primary labels, adjudicate family aliases, and assemble privately.

This does not label, freeze for training, train, or score a model. Triage may be
partial; assembly never accepts an incomplete source cohort. All record-bearing
outputs are confined to the ignored evidence-v3 private directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from groundkeeper.policy import validate_input
from scripts import collect_training_context as collector
from scripts.audit_evidence_v3 import family_plan
from scripts.prepare_delaware_labels import family_name
from scripts.prepare_evidence_v3 import POLICY, ROOT, digest, read, validate_packet, write_new

EXPECTED_COUNTS = {"delaware": 5000, "personal": 1205}
REVIEWER = {"model": "gpt-6.1-sol", "reasoning_effort": "high"}
VALID_SPLITS = {"train", "valid", "test"}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def one(path):
    values = read(path)
    if len(values) != 1 or not isinstance(values[0], dict):
        raise ValueError("Expected one manifest/assignment object")
    return values[0]


@dataclass(frozen=True)
class Layout:
    root: Path = ROOT

    @property
    def run(self):
        return self.root / ".local/finetune/evidence-v3"

    @property
    def private(self):
        return self.root / ".private/qwen-evidence-v3"

    def source(self, name):
        return (
            self.run / "source/delaware.jsonl"
            if name == "delaware"
            else self.private / "source-exact/personal.jsonl"
        )

    def packets(self, name):
        return (
            self.run / "labeling/public"
            if name == "delaware"
            else self.private / "labeling/personal"
        )

    def context(self, name):
        return (
            self.run / "context/public"
            if name == "delaware"
            else self.private / "context/personal-exact"
        )

    def destination(self, path):
        path = Path(path).resolve()
        if not path.is_relative_to(self.private.resolve()):
            raise ValueError("Private evidence output must stay under .private/qwen-evidence-v3")
        if path.exists():
            raise FileExistsError("Preserve existing audit/assembly versions")
        return path


def url(value):
    parsed = urlsplit(value) if isinstance(value, str) else None
    return bool(
        parsed
        and parsed.scheme in ("http", "https")
        and parsed.hostname
        and not parsed.username
        and not parsed.password
    )


def load_sources(layout):
    expected, bindings = {}, {}
    for name in ("delaware", "personal"):
        path = layout.source(name)
        manifest_path = path.parent / "manifest.json"
        manifest, rows = one(manifest_path), read(path)
        if (
            manifest.get("input_file_sha256") != sha(path)
            or manifest.get("count") != len(rows)
            or len(rows) != EXPECTED_COUNTS[name]
        ):
            raise ValueError("Frozen source hash/count differs from the exact requested cohort")
        if name == "personal":
            snapshot = layout.private / "snapshot/classifier_inputs.exact.jsonl"
            if manifest.get("exact_app_inputs") is not True or manifest.get(
                "snapshot_input_sha256"
            ) != sha(snapshot):
                raise ValueError(
                    "Exact private app-input snapshot is required; minimized sources are forbidden"
                )
            snapshot_rows = read(snapshot)
            snapshot_inputs = {r["id"]: r["input"] for r in snapshot_rows}
            if len(snapshot_inputs) != len(snapshot_rows) or set(snapshot_inputs) != {
                r["id"] for r in rows
            }:
                raise ValueError("Exact private snapshot IDs changed")
            if any(r["input"] != snapshot_inputs[r["id"]] for r in rows):
                raise ValueError("Private source no longer equals the exact app inputs")
            bindings[str(snapshot)] = sha(snapshot)
        elif manifest.get("policy_version") != POLICY:
            raise ValueError("Wrong public source policy")
        for row in rows:
            if row["id"] in expected:
                raise ValueError("Duplicate source ID")
            if (
                row.get("source") != name
                or row.get("input_sha256") != digest(row["input"])
                or row.get("split") not in VALID_SPLITS | {"quarantine"}
                or not row.get("merchant_family")
            ):
                raise ValueError("Source metadata or input hash changed")
            validate_input(row["input"])
            if "merchant_context" in row["input"]:
                raise ValueError("Source must contain original context-free app input")
            expected[row["id"]] = row
        bindings[str(path)], bindings[str(manifest_path)] = sha(path), sha(manifest_path)
        for relative, expected_hash in manifest.get("source_hashes", {}).items():
            original = layout.root / relative
            if sha(original) != expected_hash:
                raise ValueError("Historical source changed since cohort selection")
            bindings[str(original)] = expected_hash
    return expected, bindings


def historical_registry(layout, bindings):
    path, conflicts_path = (
        layout.run / "source/historical_families.jsonl",
        layout.run / "source/family_conflicts.jsonl",
    )
    rows, conflicts = read(path), read(conflicts_path)
    owners = defaultdict(set)
    for row in rows:
        if row["split"] not in VALID_SPLITS:
            raise ValueError("Invalid historical split")
        owners[family_name(row["merchant_family"])].add(row["split"])
    for row in conflicts:
        splits = row["historical_splits"]
        if len(set(splits)) < 2 or not set(splits) <= VALID_SPLITS:
            raise ValueError("Historical conflicts require their complete multiple owners")
        owners[family_name(row["merchant_family"])].update(splits)
    if not owners:
        raise ValueError("Full historical family registry is required")
    # Reproduce ownership only, without using historical target labels.
    manifest = one(layout.run / "source/manifest.json")
    upstream = defaultdict(set)
    for relative in manifest.get("source_hashes", {}):
        original = layout.root / relative
        for row in read(original):
            group = row.get("merchant_family", row.get("group"))
            split = row.get("split")
            if split is None and original.name.endswith(".canonical.jsonl"):
                split = original.name.split(".")[0]
            split = "valid" if split in ("validation", "val") else split
            if group and split in VALID_SPLITS:
                upstream[family_name(group)].add(split)
    if not upstream or dict(upstream) != dict(owners):
        raise ValueError("Historical registry/conflicts are incomplete or changed")
    bindings[str(path)], bindings[str(conflicts_path)] = sha(path), sha(conflicts_path)
    expanded = [
        {"merchant_family": family, "split": split}
        for family, splits in owners.items()
        for split in sorted(splits)
    ]
    return rows, owners, expanded


def context_index(layout, name, expected, bindings):
    directory = layout.context(name)
    manifest, frozen_rows, queries = collector.load(directory)
    if (
        manifest.get("private") is not (name == "personal")
        or manifest.get("synthetic_context") is not False
        or manifest.get("engine") != "duckduckgo"
        or not manifest.get("source_sha256")
        or (name == "personal" and manifest.get("ledger_query") is not True)
    ):
        raise ValueError("Production collection and exact private query projection are required")
    wanted = {i: r for i, r in expected.items() if r["source"] == name}
    if {r["id"] for r in frozen_rows} != set(wanted) or any(
        r != wanted[r["id"]] for r in frozen_rows
    ):
        raise ValueError("Context collection is stale or uses old minimized inputs")
    completed = collector.completed(directory, queries)
    for filename in ("manifest.json", "input.jsonl", "queries.jsonl"):
        bindings[str(directory / filename)] = sha(directory / filename)
    result = {}
    for identifier, record in completed.items():
        path = collector.record_path(directory, record)
        if record["input_sha256"] != digest(wanted[identifier]["input"]):
            raise ValueError("Collected context input hash changed")
        provenance = record.get("retrieval_provenance", {})
        if (
            provenance.get("engine") != "duckduckgo"
            or provenance.get("source_sha256") != manifest["source_sha256"]
        ):
            raise ValueError("Context provenance does not bind actual production collection")
        enriched = dict(wanted[identifier]["input"])
        if record["merchant_context"] is not None:
            enriched["merchant_context"] = record["merchant_context"]
        validate_input(enriched)
        query = record.get("query")
        privacy = collector.private_query_rejection(query) if name == "personal" else None
        result[identifier] = {
            "record": record,
            "path": str(path),
            "sha256": sha(path),
            "input": enriched,
            "safe_query": None if privacy else query,
            "search_privacy_rejection": privacy,
        }
        bindings[str(path)] = sha(path)
    return result


def packet_privacy_binding_matches(row, context, name):
    if (
        row.get("safe_query") == context["safe_query"]
        and row.get("search_privacy_rejection") == context["search_privacy_rejection"]
    ):
        return True
    # Early immutable packets predate the additional private query guard. Preserve
    # their original query provenance only when it exactly matches the record;
    # this does not authorize repeating that query or rewriting collected context.
    return bool(
        name == "personal"
        and context["search_privacy_rejection"]
        and context["safe_query"] is None
        and row.get("safe_query") == context["record"]["query"]
        and row.get("search_privacy_rejection") is None
    )


def exact_visible_input_audit(rows):
    """Report facts about both input-conditioned views; never choose a target.

    Grouping spans view names, so a context-free row can collide with another
    row's no-context training view. Other production evidence is kept verbatim.
    """
    grouped = defaultdict(list)
    for row in rows:
        answers = row.get("label", row)
        for variant, inputs, answer in (
            ("with_context", row["input"], answers["answer_with_context"]),
            (
                "without_context",
                {k: v for k, v in row["input"].items() if k != "merchant_context"},
                answers["answer_without_context"],
            ),
        ):
            grouped[digest(inputs)].append(
                {
                    "id": row["id"],
                    "source": row["source"],
                    "split": row["split"],
                    "variant": variant,
                    "answer": answer,
                    "answer_sha256": digest(answer),
                }
            )
    conflicts = []
    duplicate_groups = 0
    for input_hash, members in sorted(grouped.items()):
        members.sort(key=lambda m: (m["id"], m["variant"], m["split"], m["answer_sha256"]))
        answers = {}
        for member in members:
            answers.setdefault(
                member["answer_sha256"], {"answer": member["answer"], "members": []}
            )["members"].append({k: member[k] for k in ("id", "variant", "split")})
        splits = sorted({m["split"] for m in members})
        semantic = {(m["answer"]["type"], m["answer"]["category"]) for m in members}
        answer_conflict = len(answers) > 1
        type_category_conflict = len(semantic) > 1
        cross_split = len(set(splits) & VALID_SPLITS) > 1
        if len({m["id"] for m in members}) > 1:
            duplicate_groups += 1
        if answer_conflict or cross_split:
            conflicts.append(
                {
                    "input_sha256": input_hash,
                    "ids": sorted({m["id"] for m in members}),
                    "splits": splits,
                    "members": members,
                    "answer_variants": [
                        {"answer_sha256": key, **answers[key]} for key in sorted(answers)
                    ],
                    "answer_conflict": answer_conflict,
                    "type_category_conflict": type_category_conflict,
                    "review_only_conflict": answer_conflict and not type_category_conflict,
                    "cross_split": cross_split,
                }
            )
    return {
        "groups": conflicts,
        "summary": {
            "visible_input_groups": len(grouped),
            "views_audited": 2 * len(rows),
            "duplicate_input_groups": duplicate_groups,
            "conflict_groups": len(conflicts),
            "type_category_conflict_groups": sum(c["type_category_conflict"] for c in conflicts),
            "review_only_conflict_groups": sum(c["review_only_conflict"] for c in conflicts),
            "cross_split_input_groups": sum(c["cross_split"] for c in conflicts),
        },
    }


def require_consistent_retained_inputs(rows):
    result = exact_visible_input_audit(rows)
    if any(c["answer_conflict"] for c in result["groups"]):
        raise ValueError(
            "Retained identical visible inputs have conflicting targets, including review-only differences"
        )
    if any(c["cross_split"] for c in result["groups"]):
        raise ValueError("Retained identical visible inputs cross train/valid/test splits")
    return result


def inspect(layout=Layout()):
    expected, bindings = load_sources(layout)
    for code in (
        Path(__file__),
        Path(family_plan.__code__.co_filename),
        Path(validate_packet.__code__.co_filename),
    ):
        bindings[str(code.resolve())] = sha(code)
    historical, owners, expanded_history = historical_registry(layout, bindings)
    contexts = {}
    for name in ("delaware", "personal"):
        contexts.update(context_index(layout, name, expected, bindings))
    records, seen, packet_bindings = [], set(), []
    for name in ("delaware", "personal"):
        for labels_path in layout.packets(name).glob("*/labels.jsonl"):
            if not (labels_path.parent / "inputs.jsonl").is_file():
                raise ValueError("Orphan labels are not a valid bound source packet")
        for path in sorted(layout.packets(name).glob("*/inputs.jsonl")):
            assignment_path = path.parent / "assignment.json"
            assignment, packet = one(assignment_path), read(path)
            if (
                assignment.get("packet_id") != path.parent.name
                or assignment.get("count") != len(packet)
                or assignment.get("inputs_sha256") != sha(path)
                or assignment.get("model") != REVIEWER["model"]
                or assignment.get("reasoning_effort") != "high"
                or assignment.get("policy_version") != POLICY
                or assignment.get("individual_review_required") is not True
                or assignment.get("internet_search_required") is not True
            ):
                raise ValueError("Packet assignment/hash/policy changed")
            for row in packet:
                identifier = row["id"]
                if identifier not in expected or identifier in seen:
                    raise ValueError("Unexpected or duplicate packet source ID")
                seen.add(identifier)
                source, context = expected[identifier], contexts.get(identifier)
                if context is None:
                    raise ValueError("Packet lacks actual immutable collected context record")
                if (
                    source["source"] != name
                    or row.get("source") != name
                    or row.get("split") != source["split"]
                    or row.get("merchant_family") != source["merchant_family"]
                    or row["input"] != context["input"]
                    or row.get("input_sha256") != digest(context["input"])
                    or row.get("without_context_sha256") != digest(source["input"])
                    or row.get("context_record_sha256") != context["sha256"]
                    or row.get("context_outcome") != context["record"]["outcome"]
                    or not packet_privacy_binding_matches(row, context, name)
                ):
                    raise ValueError("Packet input/context/source binding is stale")
            bindings[str(path)], bindings[str(assignment_path)] = sha(path), sha(assignment_path)
            labels_path = path.parent / "labels.jsonl"
            if not labels_path.exists():
                continue
            validate_packet(path.parent)
            labels = read(labels_path)
            for source, label in zip(packet, labels):
                for search in label["searches"]:
                    if any(not url(link) for link in search["urls"]):
                        raise ValueError("Research provenance needs actual HTTP source URLs")
                records.append(
                    {
                        **source,
                        "label": label,
                        "label_sha256": digest(label),
                        "label_path": str(labels_path),
                        "source_row_sha256": digest(expected[source["id"]]),
                    }
                )
            bindings[str(labels_path)] = sha(labels_path)
            packet_bindings.append(
                {
                    "packet": str(path.parent),
                    "inputs_sha256": sha(path),
                    "labels_sha256": sha(labels_path),
                }
            )
    labeled = {r["id"] for r in records}
    if len(labeled) != len(records):
        raise ValueError("Every source ID must be individually labeled exactly once")
    components = family_plan(records, expanded_history)
    by_id = {r["id"]: r for r in records}
    for component in components:
        original = {family_name(by_id[i]["merchant_family"]) for i in component["ids"]}
        historical_names = set(component["aliases"]) & set(owners)
        component["original_families"] = sorted(original)
        component["historical_families"] = sorted(historical_names)
        component["owner_splits_by_alias"] = {
            a: sorted(owners[a]) for a in sorted(historical_names)
        }
        component["label_bindings"] = {
            i: by_id[i]["label_sha256"] for i in sorted(component["ids"])
        }
        component["risky_merge"] = len(original | historical_names) > 1
        component["unsupported_identity_renames"] = [
            i
            for i in sorted(component["ids"])
            if family_name(by_id[i]["label"]["merchant_family_proposed"])
            != family_name(by_id[i]["merchant_family"])
            and not by_id[i]["label"]["merchant_family_proposed"].casefold().startswith("unknown:")
            and not any(
                s["status"] == "results" and s["urls"] for s in by_id[i]["label"]["searches"]
            )
        ]
        component["adjudication_required"] = (
            component["risky_merge"]
            or component["status"] != "consistent"
            or bool(component["unsupported_identity_renames"])
        )
        component["component_sha256"] = digest(component)
    value = {
        "expected_count": len(expected),
        "labeled_count": len(records),
        "complete": labeled == set(expected),
        "missing_ids": sorted(set(expected) - labeled),
        "expected_counts": EXPECTED_COUNTS,
        "bindings": bindings,
        "components": components,
        "records": sorted(records, key=lambda r: r["id"]),
        "packet_bindings": packet_bindings,
        "historical": historical,
        "historical_owners": dict(owners),
        "exact_input_audit": exact_visible_input_audit(records),
    }
    value["audit_binding_sha256"] = digest(
        {
            "bindings": bindings,
            "components": components,
            "expected_ids": sorted(expected),
            "labeled_ids": sorted(labeled),
            "exact_input_audit": value["exact_input_audit"],
        }
    )
    return value


def triage(destination, layout=Layout()):
    destination = layout.destination(destination)
    result = inspect(layout)
    write_new(destination / "components.jsonl", result["components"])
    write_new(destination / "all-records.jsonl", result["records"])
    write_new(destination / "exact-input-conflicts.jsonl", result["exact_input_audit"]["groups"])
    write_new(destination / "missing-ids.jsonl", ({"id": i} for i in result["missing_ids"]))
    summary = {
        k: result[k]
        for k in (
            "expected_count",
            "labeled_count",
            "complete",
            "expected_counts",
            "bindings",
            "audit_binding_sha256",
        )
    }
    summary.update(
        policy_version=POLICY,
        retained_for_training=False,
        component_count=len(result["components"]),
        family_adjudications_required=sum(c["adjudication_required"] for c in result["components"]),
        exact_input_audit=result["exact_input_audit"]["summary"],
        artifact_hashes={
            name: sha(destination / name)
            for name in (
                "components.jsonl",
                "all-records.jsonl",
                "missing-ids.jsonl",
                "exact-input-conflicts.jsonl",
            )
        },
    )
    write_new(destination / "manifest.json", [summary])
    return {
        k: summary[k]
        for k in (
            "expected_count",
            "labeled_count",
            "complete",
            "component_count",
            "family_adjudications_required",
            "exact_input_audit",
        )
    }


def adjudicate(component, verdict, binding):
    if verdict is None:
        if component["adjudication_required"]:
            raise ValueError(
                "Risky family merge/cross-split component needs separate Sol-high adjudication"
            )
        return "accept_aliases"
    if (
        verdict.get("component_sha256") != component["component_sha256"]
        or verdict.get("audit_binding_sha256") != binding
        or verdict.get("reviewer") != REVIEWER
        or verdict.get("policy_version") != POLICY
        or verdict.get("review_scope") != "family_adjudication"
        or verdict.get("primary_label_author") is not False
        or not isinstance(verdict.get("review_task_id"), str)
        or not verdict["review_task_id"].strip()
        or not isinstance(verdict.get("rationale"), str)
        or not verdict["rationale"].strip()
        or verdict.get("decision") not in ("accept_aliases", "quarantine")
    ):
        raise ValueError(
            "Family adjudication is stale, incomplete, or not separate Sol-high review"
        )
    if verdict["decision"] == "accept_aliases" and component["status"] != "consistent":
        raise ValueError(
            "Cross-split components cannot be accepted; revise labels and re-audit or quarantine"
        )
    evidence = verdict.get("source_evidence")
    if not isinstance(evidence, list) or not evidence:
        raise ValueError("Quarantine and risky aliases require explicit review evidence")
    identifies = verdict.get("identifies_business")
    if type(identifies) is not bool:
        raise ValueError("Family adjudicator must state whether business identity is claimed")
    if identifies or verdict["decision"] == "accept_aliases":
        if not any(
            e.get("research_performed") is True
            and e.get("query")
            and e.get("finding")
            and isinstance(e.get("urls"), list)
            and e["urls"]
            and all(url(u) for u in e["urls"])
            for e in evidence
        ):
            raise ValueError(
                "Business identity/alias acceptance requires actual researched source evidence"
            )
    elif not any(
        e.get("component_sha256") == component["component_sha256"]
        and e.get("finding")
        and e.get("kind") == "structural_conflict"
        for e in evidence
    ):
        raise ValueError("Non-identity quarantine needs hash-bound structural evidence")
    return verdict["decision"]


def assemble(triage_path, adjudications, destination, layout=Layout()):
    destination = layout.destination(destination)
    if any(
        not Path(path).resolve().is_relative_to(layout.private.resolve())
        for path in (triage_path, adjudications)
    ):
        raise ValueError("Triage and family adjudications must stay in ignored private storage")
    result, prior = inspect(layout), one(Path(triage_path) / "manifest.json")
    if not result["complete"] or prior.get("complete") is not True:
        raise ValueError(
            "Refuse partial data acceptance: every expected source ID needs one individual label"
        )
    if prior.get("audit_binding_sha256") != result["audit_binding_sha256"]:
        raise ValueError("Sources, context, packets, labels, or family plan changed since triage")
    for name, expected in prior["artifact_hashes"].items():
        if sha(Path(triage_path) / name) != expected:
            raise ValueError("Immutable triage artifact changed")
    verdict_rows = read(adjudications)
    verdicts = {v["component_sha256"]: v for v in verdict_rows}
    if len(verdicts) != len(verdict_rows) or set(verdicts) - {
        c["component_sha256"] for c in result["components"]
    }:
        raise ValueError("Duplicate or unexpected family adjudication")
    by_id, canonical, all_records, decisions = {}, [], [], []
    registry = {}
    for original, splits in result["historical_owners"].items():
        registry[original] = (
            {"merchant_family": original, "split": next(iter(splits))}
            if len(splits) == 1
            else {
                "merchant_family": original,
                "split": "quarantine",
                "historical_splits": sorted(splits),
                "reason": "preserved_historical_cross_split_conflict",
            }
        )
    for component in result["components"]:
        verdict = verdicts.get(component["component_sha256"])
        decision = adjudicate(component, verdict, result["audit_binding_sha256"])
        reason = (
            "family_adjudicator_quarantine"
            if decision == "quarantine"
            else "retained_after_family_audit"
        )
        for identifier in component["ids"]:
            by_id[identifier] = (component, decision, reason)
        protected = set(component["aliases"]) | {component["canonical_family"]}
        ownership = sorted(
            set().union(*(set(v) for v in component["owner_splits_by_alias"].values()))
        )
        for alias in protected:
            registry[alias] = (
                {"merchant_family": alias, "split": component["split"]}
                if decision == "accept_aliases"
                else {
                    "merchant_family": alias,
                    "split": "quarantine",
                    "historical_splits": ownership,
                    "protected_splits": ["quarantine"],
                    "reason": reason,
                    "component_sha256": component["component_sha256"],
                }
            )
        decisions.append(
            {
                "component_sha256": component["component_sha256"],
                "decision": decision,
                "reason": reason,
                "adjudication_sha256": digest(verdict) if verdict else None,
                "structural_acceptance": verdict is None,
            }
        )
    for record in result["records"]:
        component, decision, reason = by_id[record["id"]]
        label = record["label"]
        provenance = {
            "source_row_sha256": record["source_row_sha256"],
            "primary_label_sha256": record["label_sha256"],
            "primary_label_path": record["label_path"],
            "reviewer": REVIEWER,
            "label_policy_version": POLICY,
            "searches": label["searches"],
            "rationale": label["rationale"],
            "context_quality": label["context_quality"],
            "other_reason": label.get("other_reason"),
            "context_record_sha256": record["context_record_sha256"],
            "component_sha256": component["component_sha256"],
            "family_decision": decision,
            "audit_binding_sha256": result["audit_binding_sha256"],
        }
        target = {
            "id": record["id"],
            "source": record["source"],
            "merchant_family": component["canonical_family"],
            "split": record["split"],
            "input": record["input"],
            "answer_with_context": label["answer_with_context"],
            "answer_without_context": label["answer_without_context"],
            "provenance": provenance,
        }
        all_records.append(
            {
                "canonical": target,
                "original_record": record,
                "disposition": decision,
                "reason": reason,
            }
        )
        if decision == "accept_aliases":
            if target["split"] not in VALID_SPLITS or target["split"] != component["split"]:
                raise ValueError("Assembly never silently moves heldout ownership to training")
            canonical.append(target)
    if len(all_records) != sum(EXPECTED_COUNTS.values()):
        raise ValueError("Audited all-records artifact must preserve the entire labeled corpus")
    if not canonical or not all(
        any(r["split"] == split for r in canonical) for split in VALID_SPLITS
    ):
        raise ValueError(
            "Retained dataset must still contain train, validation, and heldout splits"
        )
    retained_input_audit = require_consistent_retained_inputs(canonical)
    write_new(destination / "canonical.jsonl", canonical)
    write_new(destination / "all-records.jsonl", all_records)
    write_new(destination / "all-input-conflicts.jsonl", result["exact_input_audit"]["groups"])
    write_new(destination / "retained-input-conflicts.jsonl", retained_input_audit["groups"])
    write_new(destination / "family-decisions.jsonl", decisions)
    write_new(
        destination / "historical-family-registry.jsonl", [registry[k] for k in sorted(registry)]
    )
    write_new(destination / "family-adjudications.jsonl", verdict_rows)
    acceptance = {
        "status": "accepted",
        "labels_sha256": sha(destination / "canonical.jsonl"),
        "labels_count": len(canonical),
        "policy_version": POLICY,
        "reviewer": REVIEWER,
        "all_expected_primary_labels_present": True,
        "primary_label_count": len(all_records),
        "source_counts": dict(Counter(r["source"] for r in result["records"])),
        "audit_binding_sha256": result["audit_binding_sha256"],
        "family_adjudications_sha256": sha(destination / "family-adjudications.jsonl"),
        "reconciled_registry_sha256": sha(destination / "historical-family-registry.jsonl"),
        "human_confirmations": 0,
        "retained_exact_input_audit": retained_input_audit["summary"],
        "primary_research_status_counts": dict(
            Counter(
                "researched"
                if any(s["status"] != "privacy_blocked" for s in r["label"]["searches"])
                else "privacy_blocked"
                for r in result["records"]
            )
        ),
    }
    write_new(destination / "acceptance.json", [acceptance])
    manifest = {
        "policy_version": POLICY,
        "expected_count": result["expected_count"],
        "labeled_count": len(all_records),
        "retained_count": len(canonical),
        "quarantined_count": len(all_records) - len(canonical),
        "disposition_counts": dict(Counter(r["reason"] for r in all_records)),
        "quarantine_reason_counts": dict(
            Counter(
                next(
                    v["rationale"]
                    for v in verdict_rows
                    if v["component_sha256"] == r["canonical"]["provenance"]["component_sha256"]
                )
                for r in all_records
                if r["disposition"] == "quarantine"
            )
        ),
        "retained_source_counts": dict(Counter(r["source"] for r in canonical)),
        "retained_split_counts": dict(Counter(r["split"] for r in canonical)),
        "bindings": result["bindings"],
        "audit_binding_sha256": result["audit_binding_sha256"],
        "adjudications_input_sha256": sha(adjudications),
        "artifacts": {p.name: sha(p) for p in destination.iterdir() if p.is_file()},
        "training_started": False,
        "weak_ai_labels_not_human_gold": True,
        "all_exact_input_audit": result["exact_input_audit"]["summary"],
        "retained_exact_input_audit": retained_input_audit["summary"],
    }
    write_new(destination / "manifest.json", [manifest])
    return {
        k: manifest[k]
        for k in (
            "expected_count",
            "labeled_count",
            "retained_count",
            "quarantined_count",
            "disposition_counts",
        )
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    triage_parser = commands.add_parser("triage")
    triage_parser.add_argument("--destination", type=Path, required=True)
    assembly = commands.add_parser("assemble")
    assembly.add_argument("--triage-path", type=Path, required=True)
    assembly.add_argument("--adjudications", type=Path, required=True)
    assembly.add_argument("--destination", type=Path, required=True)
    args = vars(parser.parse_args())
    print(json.dumps(globals()[args.pop("command")](**args), sort_keys=True))


if __name__ == "__main__":
    main()
