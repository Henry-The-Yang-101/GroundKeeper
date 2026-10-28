import copy
import json

import pytest

from scripts import assemble_evidence_v3 as a
from scripts import collect_training_context as collector
from scripts.evidence_training import pipeline


def put(path, values):
    a.write_new(path, values)


def overwrite(path, values):
    path.write_text("".join(json.dumps(v, sort_keys=True) + "\n" for v in values))


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    layout = a.Layout(tmp_path)
    monkeypatch.setattr(collector, "ROOT", tmp_path)
    monkeypatch.setattr(a, "EXPECTED_COUNTS", {"delaware": 4, "personal": 1})
    history = tmp_path / "history.jsonl"
    put(history, [{"group": "historic-unrelated", "split": "test"}])
    put(
        layout.run / "source/historical_families.jsonl",
        [{"merchant_family": a.family_name("historic-unrelated"), "split": "test"}],
    )
    put(layout.run / "source/family_conflicts.jsonl", [])
    retrieval = tmp_path / "retrieval_fixture.py"
    retrieval.write_text("# fictional production-source hash fixture\n")
    source_hashes = {"retrieval_fixture.py": a.sha(retrieval)}
    sources = {}
    for name, splits in [("delaware", ["train", "valid", "test", "test"]), ("personal", ["train"])]:
        rows = []
        for i, split in enumerate(splits):
            inputs = {
                "description": f"Fictional {name} market {i}",
                "direction": "debit",
                "currency": "CAD",
            }
            rows.append(
                {
                    "id": f"{name}-{i}",
                    "source": name,
                    "split": split,
                    "merchant_family": a.family_name(f"{name} family {i}"),
                    "input": inputs,
                    "input_sha256": a.digest(inputs),
                }
            )
        sources[name] = rows
        path = layout.source(name)
        put(path, rows)
        manifest = {
            "count": len(rows),
            "input_file_sha256": a.sha(path),
            "policy_version": a.POLICY,
        }
        if name == "delaware":
            manifest["source_hashes"] = {"history.jsonl": a.sha(history)}
        else:
            snapshot = layout.private / "snapshot/classifier_inputs.exact.jsonl"
            put(snapshot, [{"id": r["id"], "input": r["input"]} for r in rows])
            manifest.update(exact_app_inputs=True, snapshot_input_sha256=a.sha(snapshot))
        put(path.parent / "manifest.json", [manifest])
        context = layout.context(name)
        put(context / "input.jsonl", rows)
        queries = [
            {
                "id": r["id"],
                "input_sha256": a.digest(r["input"]),
                "query": {"merchant": f"Fictional {name} Market", "locality": ""},
            }
            for r in rows
        ]
        put(context / "queries.jsonl", queries)
        put(
            context / "manifest.json",
            [
                {
                    "private": name == "personal",
                    "synthetic_context": False,
                    "engine": "duckduckgo",
                    "ledger_query": name == "personal",
                    "row_count": len(rows),
                    "source_sha256": source_hashes,
                    "input_sha256": a.sha(context / "input.jsonl"),
                    "queries_sha256": a.sha(context / "queries.jsonl"),
                }
            ],
        )
        for source, query in zip(rows, queries):
            record = {
                **query,
                "merchant_context": None,
                "outcome": "no_match",
                "cached": False,
                "retrieval_provenance": {
                    "engine": "duckduckgo",
                    "source_sha256": source_hashes,
                    "network_attempted": True,
                    "fixture_only": True,
                },
            }
            record_path = collector.record_path(context, source)
            put(record_path, [record])
            packet = layout.packets(name) / source["id"]
            inputs = {
                **source,
                "without_context_sha256": a.digest(source["input"]),
                "context_outcome": "no_match",
                "safe_query": query["query"],
                "search_privacy_rejection": None,
                "context_record_sha256": a.sha(record_path),
            }
            put(packet / "inputs.jsonl", [inputs])
            put(
                packet / "assignment.json",
                [
                    {
                        "packet_id": packet.name,
                        "count": 1,
                        "model": "gpt-6.1-sol",
                        "reasoning_effort": "high",
                        "policy_version": a.POLICY,
                        "internet_search_required": True,
                        "individual_review_required": True,
                        "inputs_sha256": a.sha(packet / "inputs.jsonl"),
                    }
                ],
            )
            answer = {"type": "expense", "category": "groceries", "review": True}
            label = {
                "id": source["id"],
                "input_sha256": a.digest(source["input"]),
                "reviewer": a.REVIEWER,
                "label_policy_version": a.POLICY,
                "answer_with_context": answer,
                "answer_without_context": answer,
                "merchant_family_proposed": source["merchant_family"],
                "context_quality": "absent",
                "other_reason": None,
                "rationale": "Fictional software-test fixture, not researched evidence",
                "searches": [
                    {
                        "query": "Fictional test fixture",
                        "status": "results",
                        "urls": ["https://fixture.example/identity"],
                    }
                ],
            }
            put(packet / "labels.jsonl", [label])
    return layout


def change_label(layout, name, identifier, **changes):
    path = layout.packets(name) / identifier / "labels.jsonl"
    label = a.read(path)[0]
    label.update(changes)
    overwrite(path, [label])


def decision(component, binding, decision="accept_aliases"):
    return {
        "component_sha256": component["component_sha256"],
        "audit_binding_sha256": binding,
        "reviewer": a.REVIEWER,
        "policy_version": a.POLICY,
        "review_scope": "family_adjudication",
        "primary_label_author": False,
        "review_task_id": "independent-fictional-task",
        "rationale": "Explicit fictional family adjudication fixture",
        "decision": decision,
        "identifies_business": decision == "accept_aliases",
        "source_evidence": [
            {
                "research_performed": True,
                "query": "fictional aliases",
                "urls": ["https://fixture.example/aliases"],
                "finding": "Fictional source evidence shape",
            }
            if decision == "accept_aliases"
            else {
                "kind": "structural_conflict",
                "component_sha256": component["component_sha256"],
                "finding": "These aliases cross frozen splits; preserve them in quarantine",
            }
        ],
    }


def test_valid_complete_assembly_is_consumed_by_training_freeze(corpus, monkeypatch):
    triage = corpus.private / "triage"
    assert a.triage(triage, corpus)["complete"]
    verdicts = corpus.private / "verdicts.jsonl"
    put(verdicts, [])
    output = corpus.private / "assembled"
    summary = a.assemble(triage, verdicts, output, corpus)
    assert summary["retained_count"] == 5 and summary["quarantined_count"] == 0
    assert len(a.read(output / "all-records.jsonl")) == 5
    monkeypatch.setattr(pipeline, "PRIVATE", corpus.private)
    frozen = pipeline.freeze(
        output / "canonical.jsonl",
        output / "acceptance.json",
        output / "historical-family-registry.jsonl",
        corpus.private / "frozen",
    )
    manifest, _ = pipeline.verify_frozen(frozen)
    assert manifest["labels_count"] == 5
    untouched = [
        r
        for r in a.read(output / "historical-family-registry.jsonl")
        if r["merchant_family"] == a.family_name("historic-unrelated")
    ]
    assert untouched == [{"merchant_family": a.family_name("historic-unrelated"), "split": "test"}]
    with pytest.raises(FileExistsError):
        a.assemble(triage, verdicts, output, corpus)


def test_partial_labels_never_create_acceptance(corpus):
    (corpus.packets("personal") / "personal-0/labels.jsonl").unlink()
    triage, verdicts = corpus.private / "triage", corpus.private / "verdicts"
    assert a.triage(triage, corpus)["labeled_count"] == 4
    put(verdicts, [])
    with pytest.raises(ValueError, match="partial data acceptance"):
        a.assemble(triage, verdicts, corpus.private / "assembled", corpus)
    assert not (corpus.private / "assembled/acceptance.json").exists()


def test_stale_collected_context_and_label_hashes_fail(corpus):
    path = collector.record_path(corpus.context("delaware"), {"id": "delaware-0"})
    record = a.one(path)
    record["retrieval_provenance"]["new_field"] = "changed bytes"
    overwrite(path, [record])
    with pytest.raises(ValueError, match="binding is stale"):
        a.inspect(corpus)


def test_stale_label_input_hash_fails(corpus):
    change_label(corpus, "personal", "personal-0", input_sha256="stale")
    with pytest.raises(ValueError, match="Label input hash mismatch"):
        a.inspect(corpus)


def test_old_minimized_private_source_cannot_be_accepted(corpus):
    path = corpus.source("personal").parent / "manifest.json"
    manifest = a.one(path)
    manifest["exact_app_inputs"] = False
    overwrite(path, [manifest])
    with pytest.raises(ValueError, match="minimized"):
        a.inspect(corpus)


def test_same_split_alias_merge_requires_separate_researched_adjudication(corpus):
    for name, identifier in [("delaware", "delaware-0"), ("personal", "personal-0")]:
        change_label(corpus, name, identifier, merchant_family_proposed="shared actual business")
    triage = corpus.private / "triage"
    a.triage(triage, corpus)
    result = a.inspect(corpus)
    component = next(c for c in result["components"] if c["risky_merge"])
    verdicts = corpus.private / "verdicts"
    put(verdicts, [])
    with pytest.raises(ValueError, match="separate Sol-high"):
        a.assemble(triage, verdicts, corpus.private / "rejected", corpus)
    reviewed = decision(component, result["audit_binding_sha256"])
    overwrite(verdicts, [reviewed])
    assert a.assemble(triage, verdicts, corpus.private / "accepted", corpus)["retained_count"] == 5


def test_cross_split_aliases_cannot_be_accepted_and_quarantine_stays_protected(corpus, monkeypatch):
    for identifier in ("delaware-0", "delaware-2"):
        change_label(
            corpus, "delaware", identifier, merchant_family_proposed="shared cross split business"
        )
    triage = corpus.private / "triage"
    a.triage(triage, corpus)
    result = a.inspect(corpus)
    component = next(c for c in result["components"] if c["status"] != "consistent")
    verdicts = corpus.private / "verdicts"
    put(verdicts, [decision(component, result["audit_binding_sha256"])])
    with pytest.raises(ValueError, match="cannot be accepted"):
        a.assemble(triage, verdicts, corpus.private / "unsafe", corpus)
    overwrite(verdicts, [decision(component, result["audit_binding_sha256"], "quarantine")])
    output = corpus.private / "accepted"
    summary = a.assemble(triage, verdicts, output, corpus)
    assert summary["quarantined_count"] == 2 and len(a.read(output / "all-records.jsonl")) == 5
    registry = a.read(output / "historical-family-registry.jsonl")
    for alias in [*component["aliases"], component["canonical_family"]]:
        entry = next(r for r in registry if r["merchant_family"] == alias)
        assert entry["split"] == "quarantine"
        assert entry["historical_splits"] == [] and entry["protected_splits"] == ["quarantine"]
    monkeypatch.setattr(pipeline, "PRIVATE", corpus.private)
    pipeline.freeze(
        output / "canonical.jsonl",
        output / "acceptance.json",
        output / "historical-family-registry.jsonl",
        corpus.private / "frozen",
    )
    contaminated = copy.deepcopy(a.read(output / "canonical.jsonl")[0])
    contaminated["merchant_family"] = component["aliases"][0]
    with pytest.raises(ValueError, match="crosses"):
        pipeline.validate_rows([contaminated], pipeline.validate_registry(registry))


def test_changes_after_triage_invalidate_family_review_binding(corpus):
    triage = corpus.private / "triage"
    a.triage(triage, corpus)
    change_label(
        corpus, "personal", "personal-0", rationale="A revised independently researched rationale"
    )
    verdicts = corpus.private / "verdicts"
    put(verdicts, [])
    with pytest.raises(ValueError, match="changed since triage"):
        a.assemble(triage, verdicts, corpus.private / "assembled", corpus)


def test_output_never_escapes_private_storage(corpus):
    with pytest.raises(ValueError, match="Private evidence output"):
        a.triage(corpus.run / "unsafe-output", corpus)


def test_historical_test_alias_cannot_leak_into_train(corpus):
    change_label(corpus, "delaware", "delaware-0", merchant_family_proposed="historic-unrelated")
    triage = corpus.private / "triage"
    a.triage(triage, corpus)
    inspected = a.inspect(corpus)
    component = next(c for c in inspected["components"] if c["status"] != "consistent")
    assert component["owner_splits_by_alias"] == {a.family_name("historic-unrelated"): ["test"]}
    verdicts = corpus.private / "verdicts"
    put(verdicts, [decision(component, inspected["audit_binding_sha256"], "quarantine")])
    output = corpus.private / "accepted"
    a.assemble(triage, verdicts, output, corpus)
    registry = {
        r["merchant_family"]: r for r in a.read(output / "historical-family-registry.jsonl")
    }
    historical = registry[a.family_name("historic-unrelated")]
    assert historical["split"] == "quarantine" and historical["historical_splits"] == ["test"]
    assert all(r["id"] != "delaware-0" for r in a.read(output / "canonical.jsonl"))


def test_risky_merge_cannot_claim_identity_without_researched_source(corpus):
    for name, identifier in [("delaware", "delaware-0"), ("personal", "personal-0")]:
        change_label(corpus, name, identifier, merchant_family_proposed="shared actual business")
    result = a.inspect(corpus)
    component = next(c for c in result["components"] if c["risky_merge"])
    reviewed = decision(component, result["audit_binding_sha256"])
    reviewed["source_evidence"][0]["urls"] = []
    with pytest.raises(ValueError, match="actual researched source evidence"):
        a.adjudicate(component, reviewed, result["audit_binding_sha256"])


def test_duplicate_packet_ids_and_unbound_orphan_labels_fail(corpus):
    existing = corpus.packets("delaware") / "delaware-0"
    duplicate = corpus.packets("delaware") / "duplicate"
    import shutil

    shutil.copytree(existing, duplicate)
    assignment = a.one(duplicate / "assignment.json")
    assignment["packet_id"] = "duplicate"
    overwrite(duplicate / "assignment.json", [assignment])
    with pytest.raises(ValueError, match="duplicate packet source ID"):
        a.inspect(corpus)
    shutil.rmtree(duplicate)
    put(corpus.packets("delaware") / "orphan/labels.jsonl", a.read(existing / "labels.jsonl"))
    with pytest.raises(ValueError, match="Orphan labels"):
        a.inspect(corpus)


def test_full_historical_registry_is_required(corpus):
    overwrite(
        corpus.run / "source/historical_families.jsonl",
        [{"merchant_family": "invented omitted family", "split": "train"}],
    )
    with pytest.raises(ValueError, match="incomplete or changed"):
        a.inspect(corpus)


def test_trivial_rename_without_identity_evidence_needs_adjudication(corpus):
    change_label(
        corpus,
        "personal",
        "personal-0",
        merchant_family_proposed="new business identity",
        searches=[{"query": "safe fictional query", "status": "no_reliable_match", "urls": []}],
    )
    result = a.inspect(corpus)
    component = next(c for c in result["components"] if c["ids"] == ["personal-0"])
    assert component["unsupported_identity_renames"] == ["personal-0"]
    assert component["adjudication_required"]


@pytest.mark.parametrize("legacy_query", [None, {"merchant": "Fictional AB123XYZ", "locality": ""}])
def test_explicit_private_privacy_blocked_reference_is_preserved(corpus, legacy_query):
    context = corpus.context("personal")
    queries = a.read(context / "queries.jsonl")
    queries[0]["query"] = legacy_query
    overwrite(context / "queries.jsonl", queries)
    manifest = a.one(context / "manifest.json")
    manifest["queries_sha256"] = a.sha(context / "queries.jsonl")
    overwrite(context / "manifest.json", [manifest])
    record_path = collector.record_path(context, {"id": "personal-0"})
    record = a.one(record_path)
    record.update(query=legacy_query, outcome="unsafe_query")
    record["retrieval_provenance"]["network_attempted"] = False
    overwrite(record_path, [record])
    packet = corpus.packets("personal") / "personal-0"
    inputs = a.read(packet / "inputs.jsonl")[0]
    inputs.update(
        safe_query=legacy_query, context_outcome="unsafe_query", context_record_sha256=a.sha(record_path)
    )
    overwrite(packet / "inputs.jsonl", [inputs])
    assignment = a.one(packet / "assignment.json")
    assignment["inputs_sha256"] = a.sha(packet / "inputs.jsonl")
    overwrite(packet / "assignment.json", [assignment])
    change_label(
        corpus,
        "personal",
        "personal-0",
        searches=[
            {
                "query": None,
                "status": "privacy_blocked",
                "attempted": False,
                "urls": [],
                "reason": "Fictional privacy-blocked software fixture",
            }
        ],
    )
    triage, verdicts = corpus.private / "triage", corpus.private / "verdicts"
    a.triage(triage, corpus)
    put(verdicts, [])
    output = corpus.private / "accepted"
    a.assemble(triage, verdicts, output, corpus)
    assert a.one(output / "acceptance.json")["primary_research_status_counts"] == {
        "researched": 4,
        "privacy_blocked": 1,
    }


def test_legacy_privacy_compatibility_never_accepts_changed_query_or_public_row():
    query = {"merchant": "Fictional AB123XYZ", "locality": ""}
    context = {"safe_query": None, "search_privacy_rejection": "reference_token",
               "record": {"query": query}}
    row = {"safe_query": query}
    assert a.packet_privacy_binding_matches(row, context, "personal")
    assert not a.packet_privacy_binding_matches(row, context, "delaware")
    assert not a.packet_privacy_binding_matches({"safe_query": {"merchant": "changed"}}, context, "personal")
    assert not a.packet_privacy_binding_matches(row, {**context, "search_privacy_rejection": None}, "personal")


@pytest.mark.parametrize(
    "changes",
    [
        {"reviewer": {"model": "another-model", "reasoning_effort": "high"}},
        {"label_policy_version": "old-policy"},
    ],
)
def test_wrong_label_model_or_policy_is_rejected(corpus, changes):
    change_label(corpus, "personal", "personal-0", **changes)
    with pytest.raises(ValueError, match="Wrong reviewer identity|Wrong label policy"):
        a.inspect(corpus)
