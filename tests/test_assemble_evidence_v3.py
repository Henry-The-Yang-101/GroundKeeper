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
        safe_query=legacy_query,
        context_outcome="unsafe_query",
        context_record_sha256=a.sha(record_path),
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
    context = {
        "safe_query": None,
        "search_privacy_rejection": "reference_token",
        "record": {"query": query},
    }
    row = {"safe_query": query}
    assert a.packet_privacy_binding_matches(row, context, "personal")
    assert not a.packet_privacy_binding_matches(row, context, "delaware")
    assert not a.packet_privacy_binding_matches(
        {"safe_query": {"merchant": "changed"}}, context, "personal"
    )
    assert not a.packet_privacy_binding_matches(
        row, {**context, "search_privacy_rejection": None}, "personal"
    )


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


def set_visible_input(layout, name, identifier, inputs):
    """Update a fictional source and every hash-bound collection/packet layer."""
    baseline = {k: v for k, v in inputs.items() if k != "merchant_context"}
    source_path = layout.source(name)
    rows = a.read(source_path)
    for item in rows:
        if item["id"] == identifier:
            item.update(input=baseline, input_sha256=a.digest(baseline))
    overwrite(source_path, rows)
    source_manifest_path = source_path.parent / "manifest.json"
    source_manifest = a.one(source_manifest_path)
    source_manifest["input_file_sha256"] = a.sha(source_path)
    if name == "personal":
        snapshot = layout.private / "snapshot/classifier_inputs.exact.jsonl"
        exact = a.read(snapshot)
        for item in exact:
            if item["id"] == identifier:
                item["input"] = baseline
        overwrite(snapshot, exact)
        source_manifest["snapshot_input_sha256"] = a.sha(snapshot)
    overwrite(source_manifest_path, [source_manifest])
    context = layout.context(name)
    frozen_rows = a.read(context / "input.jsonl")
    for item in frozen_rows:
        if item["id"] == identifier:
            item.update(input=baseline, input_sha256=a.digest(baseline))
    overwrite(context / "input.jsonl", frozen_rows)
    queries = a.read(context / "queries.jsonl")
    for item in queries:
        if item["id"] == identifier:
            item["input_sha256"] = a.digest(baseline)
    overwrite(context / "queries.jsonl", queries)
    manifest = a.one(context / "manifest.json")
    manifest.update(
        input_sha256=a.sha(context / "input.jsonl"), queries_sha256=a.sha(context / "queries.jsonl")
    )
    overwrite(context / "manifest.json", [manifest])
    record_path = collector.record_path(context, {"id": identifier})
    record = a.one(record_path)
    record.update(
        input_sha256=a.digest(baseline),
        merchant_context=inputs.get("merchant_context"),
        outcome="matched" if "merchant_context" in inputs else "no_match",
    )
    overwrite(record_path, [record])
    packet = layout.packets(name) / identifier
    packet_row = a.read(packet / "inputs.jsonl")[0]
    packet_row.update(
        input=inputs,
        input_sha256=a.digest(inputs),
        without_context_sha256=a.digest(baseline),
        context_record_sha256=a.sha(record_path),
        context_outcome=record["outcome"],
    )
    overwrite(packet / "inputs.jsonl", [packet_row])
    assignment = a.one(packet / "assignment.json")
    assignment["inputs_sha256"] = a.sha(packet / "inputs.jsonl")
    overwrite(packet / "assignment.json", [assignment])
    change_label(layout, name, identifier, input_sha256=a.digest(inputs))


def fictional_context(title):
    return {
        "version": "merchant-search-v1",
        "source": "duckduckgo",
        "results": [
            {
                "title": title,
                "body": "Fictional software-test context, not researched evidence.",
                "url": "https://fixture.example/context",
            }
        ],
    }


def assemble_without_family_verdicts(layout, prefix):
    triage = layout.private / (prefix + "-triage")
    a.triage(triage, layout)
    verdicts = layout.private / (prefix + "-verdicts.jsonl")
    put(verdicts, [])
    output = layout.private / (prefix + "-assembled")
    return a.assemble(triage, verdicts, output, layout), output


def test_identical_input_and_target_within_one_split_is_accepted(corpus):
    shared = {
        "description": "Fictional repeated visible purchase",
        "direction": "debit",
        "currency": "CAD",
    }
    set_visible_input(corpus, "delaware", "delaware-0", shared)
    set_visible_input(corpus, "personal", "personal-0", shared)
    summary, output = assemble_without_family_verdicts(corpus, "same-target")
    assert summary["retained_count"] == 5
    audit = a.one(output / "acceptance.json")["retained_exact_input_audit"]
    assert audit["duplicate_input_groups"] == 1 and audit["conflict_groups"] == 0
    assert not a.read(output / "retained-input-conflicts.jsonl")


def test_genuinely_different_contexts_allow_different_contextual_targets(corpus):
    shared = {"description": "Fictional opaque merchant", "direction": "debit", "currency": "CAD"}
    fallback = {"type": "expense", "category": "other", "review": True}
    for name, identifier, title, category in [
        ("delaware", "delaware-0", "Fictional restaurant", "dining"),
        ("personal", "personal-0", "Fictional grocery", "groceries"),
    ]:
        set_visible_input(
            corpus, name, identifier, {**shared, "merchant_context": fictional_context(title)}
        )
        change_label(
            corpus,
            name,
            identifier,
            answer_with_context={"type": "expense", "category": category, "review": True},
            answer_without_context=fallback,
        )
    summary, output = assemble_without_family_verdicts(corpus, "contextual")
    assert summary["retained_count"] == 5
    assert a.one(output / "acceptance.json")["retained_exact_input_audit"]["conflict_groups"] == 0


def test_partial_triage_reports_cross_view_type_category_conflicts_deterministically(corpus):
    shared = {"description": "Fictional shared baseline", "direction": "debit", "currency": "CAD"}
    set_visible_input(corpus, "delaware", "delaware-0", shared)
    set_visible_input(
        corpus,
        "personal",
        "personal-0",
        {**shared, "merchant_context": fictional_context("Fictional provider")},
    )
    change_label(
        corpus,
        "personal",
        "personal-0",
        answer_without_context={"type": "unknown", "category": "other", "review": True},
    )
    (corpus.packets("delaware") / "delaware-3/labels.jsonl").unlink()
    first, second = corpus.private / "partial-1", corpus.private / "partial-2"
    result = a.triage(first, corpus)
    a.triage(second, corpus)
    assert result["complete"] is False
    assert (first / "exact-input-conflicts.jsonl").read_bytes() == (
        second / "exact-input-conflicts.jsonl"
    ).read_bytes()
    groups = a.read(first / "exact-input-conflicts.jsonl")
    conflict = next(g for g in groups if g["input_sha256"] == a.digest(shared))
    assert conflict["type_category_conflict"] and not conflict["review_only_conflict"]
    assert conflict["ids"] == ["delaware-0", "personal-0"]
    assert conflict["splits"] == ["train"]
    assert {(m["id"], m["variant"]) for m in conflict["members"]} == {
        ("delaware-0", "with_context"),
        ("delaware-0", "without_context"),
        ("personal-0", "without_context"),
    }
    assert len(conflict["answer_variants"]) == 2
    assert a.one(first / "manifest.json")["artifact_hashes"][
        "exact-input-conflicts.jsonl"
    ] == a.sha(first / "exact-input-conflicts.jsonl")


@pytest.mark.parametrize(
    "answer,classification",
    [
        ({"type": "expense", "category": "dining", "review": True}, "type_category_conflict"),
        ({"type": "expense", "category": "groceries", "review": False}, "review_only_conflict"),
    ],
)
def test_assembly_refuses_retained_target_contradictions(corpus, answer, classification):
    shared = {
        "description": "Fictional repeated visible input",
        "direction": "debit",
        "currency": "CAD",
    }
    set_visible_input(corpus, "delaware", "delaware-0", shared)
    set_visible_input(corpus, "personal", "personal-0", shared)
    change_label(
        corpus, "personal", "personal-0", answer_with_context=answer, answer_without_context=answer
    )
    result = a.inspect(corpus)
    assert result["exact_input_audit"]["groups"][0][classification]
    with pytest.raises(ValueError, match="conflicting targets"):
        assemble_without_family_verdicts(corpus, "contradictory")
    assert not (corpus.private / "contradictory-assembled/acceptance.json").exists()


def test_identical_input_across_splits_is_refused_despite_different_families(corpus):
    shared = {
        "description": "Fictional cross-split duplicate",
        "direction": "debit",
        "currency": "CAD",
    }
    set_visible_input(corpus, "delaware", "delaware-0", shared)
    set_visible_input(corpus, "delaware", "delaware-1", shared)
    result = a.inspect(corpus)
    assert all(c["status"] == "consistent" for c in result["components"])
    conflict = next(
        g for g in result["exact_input_audit"]["groups"] if g["input_sha256"] == a.digest(shared)
    )
    assert conflict["cross_split"] and not conflict["answer_conflict"]
    assert conflict["splits"] == ["train", "valid"]
    with pytest.raises(ValueError, match="cross train/valid/test"):
        assemble_without_family_verdicts(corpus, "cross-split-input")


def test_quarantined_contradictions_remain_audited_without_blocking_retained_rows(corpus):
    shared = {
        "description": "Fictional inconsistent reference",
        "direction": "debit",
        "currency": "CAD",
    }
    set_visible_input(corpus, "delaware", "delaware-0", shared)
    set_visible_input(corpus, "personal", "personal-0", shared)
    different = {"type": "expense", "category": "dining", "review": True}
    change_label(
        corpus,
        "personal",
        "personal-0",
        answer_with_context=different,
        answer_without_context=different,
    )
    triage = corpus.private / "quarantine-input-triage"
    a.triage(triage, corpus)
    result = a.inspect(corpus)
    component = next(c for c in result["components"] if c["ids"] == ["personal-0"])
    reviewed = decision(component, result["audit_binding_sha256"], "quarantine")
    reviewed["rationale"] = (
        "Quarantine the inconsistent fictional reference pending independent repair"
    )
    reviewed["source_evidence"][0]["finding"] = (
        "This component supplies a contradictory target for the exact retained visible input"
    )
    verdicts = corpus.private / "input-conflict-verdicts.jsonl"
    put(verdicts, [reviewed])
    output = corpus.private / "quarantined-input-assembled"
    assert a.assemble(triage, verdicts, output, corpus)["retained_count"] == 4
    assert len(a.read(output / "all-records.jsonl")) == 5
    assert a.read(output / "all-input-conflicts.jsonl")
    assert not a.read(output / "retained-input-conflicts.jsonl")
    assert all(r["id"] != "personal-0" for r in a.read(output / "canonical.jsonl"))
    assert a.one(output / "manifest.json")["retained_exact_input_audit"]["conflict_groups"] == 0


def test_no_context_view_retains_other_visible_evidence():
    base = {"description": "Fictional merchant", "direction": "debit", "currency": "CAD"}
    answer = {"type": "expense", "category": "groceries", "review": True}
    rows = [
        {
            "id": str(i),
            "source": "fictional",
            "split": "train",
            "input": {
                **base,
                "transaction_notes": note,
                "merchant_context": fictional_context("Fictional"),
            },
            "answer_with_context": answer,
            "answer_without_context": answer,
        }
        for i, note in enumerate(("Fictional grocery purchase", "Fictional other purchase"))
    ]
    assert a.exact_visible_input_audit(rows)["summary"]["conflict_groups"] == 0
    assert a.exact_visible_input_audit(rows)["summary"]["duplicate_input_groups"] == 0


@pytest.mark.parametrize("generic_search", [False, True])
def test_public_no_safe_query_assembly_roundtrip_tracks_truthful_research_counts(
    corpus, monkeypatch, generic_search
):
    context = corpus.context("delaware")
    queries = a.read(context / "queries.jsonl")
    for query in queries:
        if query["id"] == "delaware-0":
            query["query"] = None
    overwrite(context / "queries.jsonl", queries)
    manifest = a.one(context / "manifest.json")
    manifest["queries_sha256"] = a.sha(context / "queries.jsonl")
    overwrite(context / "manifest.json", [manifest])
    record_path = collector.record_path(context, {"id": "delaware-0"})
    record = a.one(record_path)
    record.update(query=None, outcome="unsafe_query")
    record["retrieval_provenance"]["network_attempted"] = False
    overwrite(record_path, [record])
    packet = corpus.packets("delaware") / "delaware-0"
    inputs = a.read(packet / "inputs.jsonl")[0]
    inputs.update(
        safe_query=None, context_outcome="unsafe_query", context_record_sha256=a.sha(record_path)
    )
    overwrite(packet / "inputs.jsonl", [inputs])
    assignment = a.one(packet / "assignment.json")
    assignment["inputs_sha256"] = a.sha(packet / "inputs.jsonl")
    overwrite(packet / "assignment.json", [assignment])
    searches = [
        {
            "query": None,
            "status": "no_safe_query",
            "attempted": False,
            "urls": [],
            "reason": "Fictional public fixture has no frozen safe query",
        }
    ]
    if generic_search:
        searches.append(
            {
                "query": "Fictional generic public-provider documentation fixture",
                "status": "results",
                "urls": ["https://fixture.example/public-documentation"],
            }
        )
    change_label(corpus, "delaware", "delaware-0", searches=searches)
    summary, output = assemble_without_family_verdicts(corpus, "public-null-query")
    assert summary["retained_count"] == 5
    counts = a.one(output / "acceptance.json")["primary_research_status_counts"]
    assert counts == (
        {"researched": 5} if generic_search else {"researched": 4, "no_safe_query": 1}
    )
    canonical = next(r for r in a.read(output / "canonical.jsonl") if r["id"] == "delaware-0")
    assert canonical["provenance"]["searches"] == searches
    assert canonical["input"] == inputs["input"]
    monkeypatch.setattr(pipeline, "PRIVATE", corpus.private)
    frozen = pipeline.freeze(
        output / "canonical.jsonl",
        output / "acceptance.json",
        output / "historical-family-registry.jsonl",
        corpus.private / "frozen-public-null-query",
    )
    assert pipeline.verify_frozen(frozen)[0]["labels_count"] == 5
