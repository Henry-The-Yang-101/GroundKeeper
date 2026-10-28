"""Offline verification of immutable snapshots and production retrieval orchestration."""

import json
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from groundkeeper.merchant_search import MerchantSearch
from scripts import collect_training_context as collector


def row(identifier, description="Fictional Cafe"):
    return {
        "id": identifier, "input": {"description": description, "notes": "private note",
                                    "account": "private account", "receipt_context": "private receipt"},
        "source": "fictional", "merchant_family": "fictional", "split": "test",
    }


@pytest.fixture
def snapshot(tmp_path, monkeypatch):
    monkeypatch.setattr(collector, "ROOT", tmp_path)
    monkeypatch.setattr(collector, "source_hashes", lambda paths=None: {"production": "fixed"})
    monkeypatch.setattr(collector, "project", lambda rows, ledger_query=False: [
        {"id": item["id"], "query": None if item["input"]["description"] == "unsafe" else {
            "merchant": item["input"]["description"], "locality": ""}}
        for item in rows
    ])

    def create(rows, private=False, ledger_query=False):
        source = tmp_path / "source.jsonl"
        source.write_text("".join(collector.canonical(item) + "\n" for item in rows))
        directory = tmp_path / (".private" if private else ".local") / "context"
        directory.mkdir(parents=True)
        collector.prepare(directory, source, private, ledger_query)
        return directory, source

    return create


class Clock:
    def __init__(self):
        self.epoch = time.time()
        self.elapsed = 0.0

    def time(self):
        return self.epoch + self.elapsed

    def monotonic(self):
        return self.elapsed

    def sleep(self, seconds):
        self.elapsed += seconds


class Search(MerchantSearch):
    """Keep production handle validation; replace only the network operation."""
    def __init__(self, clock, outcomes=("no_match",)):
        super().__init__()
        self.clock, self.outcomes, self.calls = clock, iter(outcomes), []

    def search(self, merchant, locality, cancelled, event):
        self.calls.append((merchant, locality, self.clock.time()))
        self.clock.sleep(2)
        outcome = next(self.outcomes)
        context = {"version": "merchant-search-v1", "source": "duckduckgo", "results": [
            {"title": "Fictional Cafe", "body": "Fictional Cafe serves coffee.",
             "url": "https://example.org/cafe"}]} if outcome == "matched" else None
        return {"outcome": outcome, "context": context}


def test_prepare_preserves_full_source_and_is_idempotent(snapshot):
    rows = [row("opaque-1")]
    directory, source = snapshot(rows)
    assert collector.read_rows(directory / "input.jsonl") == rows
    assert collector.prepare(directory, source)["completed"] == 0
    rows[0]["split"] = "train"
    source.write_text(json.dumps(rows[0]) + "\n")
    with pytest.raises(ValueError, match="Frozen inputs changed"):
        collector.prepare(directory, source)


def test_project_exposes_only_description_to_actual_swift_command(tmp_path, monkeypatch):
    monkeypatch.setattr(collector, "ROOT", tmp_path)
    (tmp_path / ".local").mkdir()

    def run(command, **kwargs):
        assert command[:2] == ["swift", "run"]
        assert "MerchantQueryPilot" in command
        payload = collector.read_rows(Path(command[-1]))
        assert payload == [{"id": "opaque", "input": {"description": "Fictional Cafe"}}]
        assert kwargs["capture_output"] and kwargs["check"] and kwargs["timeout"] == 300
        return SimpleNamespace(stdout='{"id":"opaque","query":{"merchant":"Fictional Cafe","locality":""}}\n')

    monkeypatch.setattr(collector.subprocess, "run", run)
    assert collector.project([row("opaque")])[0]["query"]["merchant"] == "Fictional Cafe"


def test_actual_swift_sanitizer_rejects_private_transfers_and_strips_descriptors():
    projected = collector.project([
        row("safe", "POS Fictional Cafe 1234 AUTH private-value"),
        row("unsafe", "Interac e-transfer to Private Person"),
    ])
    assert projected == [
        {"id": "safe", "query": {"merchant": "Fictional Cafe", "locality": ""}},
        {"id": "unsafe", "query": None},
    ]


@pytest.mark.parametrize("filename", ["input.jsonl", "queries.jsonl"])
def test_frozen_files_cannot_be_changed(snapshot, filename):
    directory, _ = snapshot([row("opaque")])
    with (directory / filename).open("a") as stream:
        stream.write("\n")
    with pytest.raises(ValueError, match="Frozen input/query file changed"):
        collector.load(directory)


def test_source_drift_stops_before_network(snapshot, monkeypatch):
    directory, _ = snapshot([row("opaque")])
    monkeypatch.setattr(collector, "source_hashes", lambda paths=None: {"production": "changed"})
    clock = Clock()
    search = Search(clock)
    with pytest.raises(ValueError, match="Production retrieval/sanitizer source changed"):
        collector.collect(directory, 1, 60, search, clock)
    assert not search.calls


def test_lookup_limit_cache_dedup_and_resumption_bind_exact_queries(snapshot, capsys):
    directory, _ = snapshot([row("first"), row("duplicate"), row("other", "Other Shop")])
    clock = Clock()
    search = Search(clock, ("matched", "no_match"))
    first = collector.collect(directory, 1, 60, search, clock)
    assert first["completed"] == 2 and first["stop_reason"] == "lookup_limit"
    records = collector.read_rows(directory / "records.jsonl")
    original = (directory / "records.jsonl").read_text()
    assert records[0]["merchant_context"] == records[1]["merchant_context"]
    assert records[1]["cached"] and records[1]["retrieval_provenance"]["cache_source_id"] == "first"
    assert records[0]["retrieval_provenance"]["network_attempted"]
    assert not records[1]["retrieval_provenance"]["network_attempted"]
    resumed = collector.collect(directory, 1, 60, search, clock)
    assert resumed["completed"] == 3 and resumed["stop_reason"] == "complete"
    assert (directory / "records.jsonl").read_text().startswith(original)
    assert search.calls[1][2] - search.calls[0][2] == pytest.approx(12.5)
    assert search.calls[0][:2] == ("Fictional Cafe", "")
    output = capsys.readouterr().out
    assert "private" not in output and "Fictional" not in output and "opaque" not in output


@pytest.mark.parametrize("outcome,delay", [("blocked", 900), ("unavailable", 60)])
def test_provider_failure_stops_and_resume_preserves_pending_during_backoff(snapshot, outcome, delay):
    directory, _ = snapshot([row("first"), row("other", "Other Shop")])
    clock = Clock()
    search = Search(clock, (outcome, "no_match"))
    first = collector.collect(directory, 5, 100, search, clock)
    assert first["completed"] == 1 and first["stop_reason"] == "provider_" + outcome
    state = collector.load_state(directory)
    assert state["not_before_ms"] == int(clock.time() * 1000) + delay * 1000
    assert not state["cache"]
    resumed = collector.collect(directory, 5, 100, search, clock)
    assert resumed["completed"] == 1 and resumed["stop_reason"] == "backoff"
    assert len(search.calls) == 1
    clock.sleep(delay)
    assert collector.collect(directory, 5, 100, search, clock)["completed"] == 2


def test_unsafe_query_never_searches_and_bound_prevents_dispatch_during_spacing(snapshot):
    directory, _ = snapshot([row("unsafe", "unsafe"), row("first"), row("other", "Other Shop")])
    clock = Clock()
    search = Search(clock)
    result = collector.collect(directory, 5, 5, search, clock)
    assert result["completed"] == 2 and result["stop_reason"] == "runtime_limit"
    assert len(search.calls) == 1
    assert collector.read_rows(directory / "records.jsonl")[0]["outcome"] == "unsafe_query"


def test_cache_expiry_and_capacity_match_production():
    evidence = {"outcome": "no_match", "context": None}
    state = {"cache": {str(i): {"evidence": evidence, "fetched_at_ms": i} for i in range(1002)}}
    collector.prune_cache(state, 2000)
    assert len(state["cache"]) == 1000 and "0" not in state["cache"] and "1" not in state["cache"]
    collector.prune_cache(state, 86_400_000 + 1001)
    assert not state["cache"]
    context = {"version": "merchant-search-v1", "source": "duckduckgo", "results": [
        {"title": "Cafe", "body": "Cafe serves coffee.", "url": "https://example.org/"}]}
    state["cache"]["matched"] = {"evidence": {"outcome": "matched", "context": context}, "fetched_at_ms": 0}
    collector.prune_cache(state, 86_400_000)
    assert "matched" in state["cache"]
    collector.prune_cache(state, 2_592_000_000)
    assert not state["cache"]


def test_records_are_never_overwritten_or_accepted_for_another_input(snapshot):
    directory, _ = snapshot([row("first")])
    clock = Clock()
    collector.collect(directory, 1, 60, Search(clock), clock)
    query = collector.read_rows(directory / "queries.jsonl")[0]
    path = collector.record_path(directory, query)
    with pytest.raises(FileExistsError):
        collector.write_json(path, {"replacement": True}, immutable=True)
    value = json.loads(path.read_text())
    value["input_sha256"] = "different"
    path.write_text(json.dumps(value))
    with pytest.raises(ValueError, match="Completed record does not match"):
        collector.status(directory)


def test_persisted_reservation_and_exclusive_lock_prevent_duplicate_dispatch(snapshot):
    directory, _ = snapshot([row("first")])
    clock = Clock()
    collector.write_json(directory / "state.json", {"not_before_ms": int(clock.time() * 1000) + 45_000, "cache": {}})
    search = Search(clock)
    assert collector.collect(directory, 1, 60, search, clock)["stop_reason"] == "backoff"
    assert not search.calls
    with collector.exclusive(directory):
        with pytest.raises(ValueError, match="Another collector"):
            with collector.exclusive(directory):
                pass


def test_corrupt_state_cannot_relax_throttle(snapshot):
    directory, _ = snapshot([row("first")])
    collector.write_json(directory / "state.json", {"not_before_ms": -1, "cache": {}})
    with pytest.raises(ValueError, match="Invalid persisted collection state"):
        collector.load_state(directory)


def test_private_inputs_require_private_output(snapshot, tmp_path):
    directory, source = snapshot([row("first")])
    other = tmp_path / ".local" / "other"
    other.mkdir()
    with pytest.raises(ValueError, match="Private inputs must"):
        collector.prepare(other, source, private=True)


def test_actual_ledger_query_uses_stored_merchant_and_locality_with_description_fallback():
    rows = [
        {**row("stored", "POS Fallback Cafe 1234 AUTH private-value"),
         "search_merchant": "Named Shop", "search_locality": " Waterloo ON "},
        {**row("fallback", "POS Fallback Cafe 1234 AUTH private-value"),
         "search_merchant": None, "search_locality": None},
        {**row("unsafe", "Fictional Cafe"),
         "search_merchant": "e-transfer to Private Person", "search_locality": "Waterloo"},
    ]
    assert collector.project(rows, ledger_query=True) == [
        {"id": "stored", "query": {"merchant": "Named Shop", "locality": "Waterloo ON"}},
        {"id": "fallback", "query": {"merchant": "Fallback Cafe", "locality": ""}},
        {"id": "unsafe", "query": None},
    ]


def test_ledger_projection_subprocess_receives_only_exact_make_arguments(tmp_path, monkeypatch):
    monkeypatch.setattr(collector, "ROOT", tmp_path)
    original = {**row("opaque"), "search_merchant": "Named Shop", "search_locality": "Waterloo"}
    original["input"]["amount"] = "123.45"

    def run(command, **kwargs):
        assert "MerchantTrainingQueryPilot" in command
        source = Path(command[-1])
        assert source.is_relative_to(tmp_path / ".private")
        assert collector.read_rows(source) == [{
            "id": "opaque", "input": {"description": "Fictional Cafe"},
            "search_merchant": "Named Shop", "search_locality": "Waterloo",
        }]
        return SimpleNamespace(stdout='{"id":"opaque","query":{"merchant":"Named Shop","locality":"Waterloo"}}\n')

    monkeypatch.setattr(collector.subprocess, "run", run)
    assert collector.project([original], ledger_query=True)[0]["query"] == {
        "merchant": "Named Shop", "locality": "Waterloo"}


def test_ledger_projection_rejects_nontext_snapshot_fields_before_swift(tmp_path, monkeypatch):
    monkeypatch.setattr(collector, "ROOT", tmp_path)
    with pytest.raises(ValueError, match="merchant/locality must be strings"):
        collector.project([{**row("opaque"), "search_merchant": {"name": "Cafe"}}], ledger_query=True)


def test_ledger_mode_is_frozen_and_cannot_reuse_legacy_projection(snapshot):
    rows = [{**row("opaque"), "search_merchant": "Named Shop", "search_locality": "Waterloo"}]
    directory, source = snapshot(rows, private=True, ledger_query=True)
    manifest, _, _ = collector.load(directory)
    assert manifest["ledger_query"] is True
    assert "MerchantTrainingQueryPilot" in manifest["query_projection"]
    assert collector.prepare(directory, source, private=True, ledger_query=True)["pending"] == 1
    with pytest.raises(ValueError, match="Frozen inputs changed"):
        collector.prepare(directory, source, private=True)


def test_legacy_load_checks_manifest_source_keys_after_new_target_is_added(snapshot, monkeypatch):
    directory, source = snapshot([row("opaque")])
    manifest = json.loads((directory / "manifest.json").read_text())
    del manifest["ledger_query"]
    collector.write_json(directory / "manifest.json", manifest)
    observed = []

    def source_hashes(paths=None):
        observed.append(paths)
        assert set(paths) == {"production"}
        return {"production": "fixed"}

    monkeypatch.setattr(collector, "source_hashes", source_hashes)
    assert collector.prepare(directory, source)["pending"] == 1
    assert observed


def test_ledger_network_handle_receives_only_sanitized_query(snapshot, monkeypatch):
    rows = [{**row("opaque"), "search_merchant": "Named Shop", "search_locality": "Waterloo"}]
    monkeypatch.setattr(collector, "project", lambda values, ledger_query=False: [
        {"id": values[0]["id"], "query": {"merchant": "Named Shop", "locality": "Waterloo"}}])
    directory, _ = snapshot(rows, private=True, ledger_query=True)
    clock = Clock()
    search = Search(clock)
    requests = []
    handle = search.handle

    def inspect(request, **kwargs):
        requests.append(request)
        return handle(request, **kwargs)

    monkeypatch.setattr(search, "handle", inspect)
    assert collector.collect(directory, 1, 60, search, clock)["completed"] == 1
    assert requests == [{
        "protocol_version": 1, "request_id": "training-context", "operation": "merchant_search",
        "merchant": "Named Shop", "locality": "Waterloo",
    }]
