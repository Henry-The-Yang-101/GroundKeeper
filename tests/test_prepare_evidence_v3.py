import json

import pytest

from scripts.prepare_evidence_v3 import digest, packets, validate_packet, write_new


def fixture(tmp_path, *, context=None):
    original = {"description": "FICTIONAL CAFE", "direction": "debit", "currency": "CAD"}
    source = tmp_path / "source.jsonl"
    write_new(source, [{"id": "fictional-1", "split": "train", "source": "personal",
                        "merchant_family": "fictional-cafe", "input": original}])
    directory = tmp_path / "context"
    write_new(directory / "records/row.json", [{"id": "fictional-1", "input_sha256": digest(original),
                "merchant_context": context, "outcome": "matched" if context else "no_match",
                "query": {"merchant": "FICTIONAL CAFE", "locality": ""}}])
    result = packets(source, directory, tmp_path / "packets")
    packet = tmp_path / "packets" / result["created"][0]["packet"].split("/")[-1]
    row = json.loads((packet / "inputs.jsonl").read_text())
    answer = {"type": "expense", "category": "dining", "review": False}
    label = {"id": row["id"], "input_sha256": row["input_sha256"],
             "answer_with_context": answer, "answer_without_context": answer,
             "reviewer": {"model": "gpt-6.1-sol", "reasoning_effort": "high"},
             "label_policy_version": "groundkeeper-19-v2", "merchant_family_proposed": "fictional-cafe",
             "context_quality": "useful" if context else "absent", "other_reason": None,
             "rationale": "Fictional cafe descriptor supports dining.",
             "searches": [{"query": "FICTIONAL CAFE", "status": "no_reliable_match", "urls": []}]}
    return source, directory, packet, label


def test_packets_resume_and_bind_enriched_context(tmp_path):
    context = {"version": "merchant-search-v1", "source": "duckduckgo", "results": [
        {"title": "Fictional Cafe", "body": "Fictional restaurant fixture", "url": "https://example.com/cafe"}]}
    source, directory, packet, label = fixture(tmp_path, context=context)
    row = json.loads((packet / "inputs.jsonl").read_text())
    assert row["input_sha256"] != row["without_context_sha256"]
    assert row["input"]["merchant_context"] == context
    assert packets(source, directory, tmp_path / "packets")["new_rows"] == 0
    write_new(packet / "labels.jsonl", [label])
    assert validate_packet(packet)["validated"] == 1


@pytest.mark.parametrize("mutation", ["no_search", "wrong_hash", "wrong_model", "old_category", "different_no_context", "invented_success"])
def test_invalid_research_targets_rejected(tmp_path, mutation):
    _, _, packet, label = fixture(tmp_path)
    if mutation == "no_search":
        label["searches"] = []
    elif mutation == "wrong_hash":
        label["input_sha256"] = "bad"
    elif mutation == "wrong_model":
        label["reviewer"]["model"] = "other"
    elif mutation == "old_category":
        label["answer_with_context"]["category"] = "uncategorized"
    elif mutation == "different_no_context":
        label["answer_without_context"] = {"type": "unknown", "category": "other", "review": True}
    else:
        label["searches"][0]["status"] = "results"
    write_new(packet / "labels.jsonl", [label])
    with pytest.raises(ValueError):
        validate_packet(packet)


def test_wrong_context_source_hash_rejected(tmp_path):
    source, directory, _, _ = fixture(tmp_path)
    path = directory / "records/row.json"
    row = json.loads(path.read_text())
    row["input_sha256"] = "wrong"
    path.write_text(json.dumps(row))
    with pytest.raises(ValueError, match="Context does not match"):
        packets(source, directory, tmp_path / "other_packets")


def test_private_legacy_reference_query_is_hidden_from_new_label_packet(tmp_path):
    source, directory, _, _ = fixture(tmp_path)
    path = directory / "records/row.json"
    context = json.loads(path.read_text())
    context["query"] = {"merchant": "MARKETPLACE AB12CD34", "locality": ""}
    path.write_text(json.dumps(context))
    out = tmp_path / "privacy_packets"
    result = packets(source, directory, out)
    packet = out / result["created"][0]["packet"].split("/")[-1]
    row = json.loads((packet / "inputs.jsonl").read_text())
    assert row["safe_query"] is None
    assert row["search_privacy_rejection"] == "mixed_alphanumeric_reference"
    assert json.loads(path.read_text())["query"]["merchant"] == "MARKETPLACE AB12CD34"


def test_privacy_blocked_is_explicit_not_fake_search(tmp_path):
    _, _, packet, label = fixture(tmp_path)
    path = packet / "inputs.jsonl"
    row = json.loads(path.read_text())
    row["safe_query"] = None
    path.write_text(json.dumps(row))
    label["searches"] = [{"query": None, "status": "privacy_blocked", "attempted": False,
                          "urls": [], "reason": "No permitted merchant query"}]
    write_new(packet / "labels.jsonl", [label])
    assert validate_packet(packet)["validated"] == 1
    row["safe_query"] = {"merchant": "MARKETPLACE AB12CD34", "locality": ""}
    path.write_text(json.dumps(row))
    assert validate_packet(packet)["validated"] == 1
    row["safe_query"] = {"merchant": "Fictional Cafe", "locality": ""}
    path.write_text(json.dumps(row))
    with pytest.raises(ValueError, match="Privacy-blocked"):
        validate_packet(packet)
    row["safe_query"] = None
    path.write_text(json.dumps(row))
    label["searches"][0]["attempted"] = True
    (packet / "labels.jsonl").write_text(json.dumps(label))
    with pytest.raises(ValueError, match="Privacy-blocked"):
        validate_packet(packet)


def no_safe_query_provenance():
    return {
        "query": None,
        "status": "no_safe_query",
        "attempted": False,
        "urls": [],
        "reason": "Fictional fixture has no frozen safe query",
    }


@pytest.mark.parametrize("source", ["delaware", "personal"])
def test_no_safe_query_explicitly_records_no_search_for_either_source(tmp_path, source):
    _, _, packet, label = fixture(tmp_path)
    path = packet / "inputs.jsonl"
    row = json.loads(path.read_text())
    row.update(source=source, safe_query=None, context_outcome="unsafe_query")
    path.write_text(json.dumps(row))
    label["searches"] = [no_safe_query_provenance()]
    write_new(packet / "labels.jsonl", [label])
    assert validate_packet(packet)["validated"] == 1


@pytest.mark.parametrize(
    "invalid",
    [
        "safe_query",
        "legacy_rejected_query",
        "query",
        "attempted",
        "urls",
        "reason",
        "missing_query",
        "missing_frozen_query",
    ],
)
def test_no_safe_query_refuses_false_flags_attempts_and_urls(tmp_path, invalid):
    _, _, packet, label = fixture(tmp_path)
    path = packet / "inputs.jsonl"
    row = json.loads(path.read_text())
    row["safe_query"] = None
    search = no_safe_query_provenance()
    if invalid == "safe_query":
        row["safe_query"] = {"merchant": "Fictional Cafe", "locality": ""}
    elif invalid == "legacy_rejected_query":
        row["safe_query"] = {"merchant": "Fictional Reference AB12CD34", "locality": ""}
    elif invalid == "query":
        search["query"] = "Invented query"
    elif invalid == "attempted":
        search["attempted"] = True
    elif invalid == "urls":
        search["urls"] = ["https://fixture.example/not-a-search"]
    elif invalid == "reason":
        search["reason"] = "   "
    elif invalid == "missing_query":
        del search["query"]
    else:
        del row["safe_query"]
    path.write_text(json.dumps(row))
    label["searches"] = [search]
    write_new(packet / "labels.jsonl", [label])
    with pytest.raises(ValueError, match="No-safe-query provenance"):
        validate_packet(packet)


def test_privacy_blocked_remains_private_only_for_null_queries(tmp_path):
    _, _, packet, label = fixture(tmp_path)
    path = packet / "inputs.jsonl"
    row = json.loads(path.read_text())
    row.update(source="delaware", safe_query=None)
    path.write_text(json.dumps(row))
    label["searches"] = [{**no_safe_query_provenance(), "status": "privacy_blocked"}]
    write_new(packet / "labels.jsonl", [label])
    with pytest.raises(ValueError, match="Privacy-blocked"):
        validate_packet(packet)
