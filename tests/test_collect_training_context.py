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
        "id": identifier,
        "input": {
            "description": description,
            "notes": "private note",
            "account": "private account",
            "receipt_context": "private receipt",
        },
        "source": "fictional",
        "merchant_family": "fictional",
        "split": "test",
    }


@pytest.fixture
def snapshot(tmp_path, monkeypatch):
    monkeypatch.setattr(collector, "ROOT", tmp_path)
    monkeypatch.setattr(collector, "source_hashes", lambda paths=None: {"production": "fixed"})
    monkeypatch.setattr(
        collector,
        "project",
        lambda rows, ledger_query=False: [
            {
                "id": item["id"],
                "query": None
                if item["input"]["description"] == "unsafe"
                else {"merchant": item["input"]["description"], "locality": ""},
            }
            for item in rows
        ],
    )

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
        context = (
            {
                "version": "merchant-search-v1",
                "source": "duckduckgo",
                "results": [
                    {
                        "title": "Fictional Cafe",
                        "body": "Fictional Cafe serves coffee.",
                        "url": "https://example.org/cafe",
                    }
                ],
            }
            if outcome == "matched"
            else None
        )
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
        return SimpleNamespace(
            stdout='{"id":"opaque","query":{"merchant":"Fictional Cafe","locality":""}}\n'
        )

    monkeypatch.setattr(collector.subprocess, "run", run)
    assert collector.project([row("opaque")])[0]["query"]["merchant"] == "Fictional Cafe"


def test_actual_swift_sanitizer_rejects_private_transfers_and_strips_descriptors():
    projected = collector.project(
        [
            row("safe", "POS Fictional Cafe 1234 AUTH private-value"),
            row("unsafe", "Interac e-transfer to Private Person"),
        ]
    )
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
def test_provider_failure_stops_and_resume_preserves_pending_during_backoff(
    snapshot, outcome, delay
):
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
    context = {
        "version": "merchant-search-v1",
        "source": "duckduckgo",
        "results": [
            {"title": "Cafe", "body": "Cafe serves coffee.", "url": "https://example.org/"}
        ],
    }
    state["cache"]["matched"] = {
        "evidence": {"outcome": "matched", "context": context},
        "fetched_at_ms": 0,
    }
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
    collector.write_json(
        directory / "state.json", {"not_before_ms": int(clock.time() * 1000) + 45_000, "cache": {}}
    )
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
        {
            **row("stored", "POS Fallback Cafe 1234 AUTH private-value"),
            "search_merchant": "Named Shop",
            "search_locality": " Waterloo ON ",
        },
        {
            **row("fallback", "POS Fallback Cafe 1234 AUTH private-value"),
            "search_merchant": None,
            "search_locality": None,
        },
        {
            **row("unsafe", "Fictional Cafe"),
            "search_merchant": "e-transfer to Private Person",
            "search_locality": "Waterloo",
        },
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
        assert collector.read_rows(source) == [
            {
                "id": "opaque",
                "input": {"description": "Fictional Cafe"},
                "search_merchant": "Named Shop",
                "search_locality": "Waterloo",
            }
        ]
        return SimpleNamespace(
            stdout='{"id":"opaque","query":{"merchant":"Named Shop","locality":"Waterloo"}}\n'
        )

    monkeypatch.setattr(collector.subprocess, "run", run)
    assert collector.project([original], ledger_query=True)[0]["query"] == {
        "merchant": "Named Shop",
        "locality": "Waterloo",
    }


def test_ledger_projection_rejects_nontext_snapshot_fields_before_swift(tmp_path, monkeypatch):
    monkeypatch.setattr(collector, "ROOT", tmp_path)
    with pytest.raises(ValueError, match="merchant/locality must be strings"):
        collector.project(
            [{**row("opaque"), "search_merchant": {"name": "Cafe"}}], ledger_query=True
        )


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
    monkeypatch.setattr(
        collector,
        "project",
        lambda values, ledger_query=False: [
            {"id": values[0]["id"], "query": {"merchant": "Named Shop", "locality": "Waterloo"}}
        ],
    )
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
    assert requests == [
        {
            "protocol_version": 1,
            "request_id": "training-context",
            "operation": "merchant_search",
            "merchant": "Named Shop",
            "locality": "Waterloo",
        }
    ]


@pytest.mark.parametrize(
    "merchant",
    [
        "AMZNMKTPL CA AB12CD34",
        "DIGITALBILL CA Z9YXW8V7",
        "Fictional Shop AB12-CD34",
        "Fictional Shop AB12",
        "Fictional Shop ab12cd34",
        "Fictional Shop A123",
        "Fictional Shop 123A",
    ],
)
def test_private_query_guard_rejects_identifier_candidates_without_rewriting(merchant):
    query = {"merchant": merchant, "locality": ""}
    original = dict(query)
    assert collector.private_query_rejection(query) == "mixed_alphanumeric_reference"
    assert query == original


@pytest.mark.parametrize(
    "merchant", ["Fictional Cafe", "3M", "7-Eleven", "B2B Cafe", "Studio Cafe"]
)
def test_private_query_guard_accepts_nonsensitive_names(merchant):
    assert collector.private_query_rejection({"merchant": merchant, "locality": ""}) is None


def test_private_guard_runs_before_cache_and_network_and_records_actual_candidate(snapshot):
    directory, _ = snapshot(
        [
            row("marketplace", "AMZNMKTPL CA AB12CD34"),
            row("digital", "DIGITALBILL CA Z9YXW8V7"),
            row("ordinary"),
        ],
        private=True,
    )
    clock = Clock()
    risky_query = {"merchant": "AMZNMKTPL CA AB12CD34", "locality": ""}
    collector.write_json(
        directory / "state.json",
        {
            "not_before_ms": 0,
            "cache": {
                collector.cache_key(risky_query): {
                    "evidence": {"outcome": "no_match", "context": None},
                    "fetched_at_ms": int(clock.time() * 1000),
                    "source_id": "earlier",
                }
            },
        },
    )
    search = Search(clock)
    result = collector.collect(directory, 1, 60, search, clock)
    assert result["completed"] == 3 and result["lookups_this_run"] == 1
    assert result["privacy_rejected_rows"] == 2
    assert len(search.calls) == 1 and search.calls[0][0] == "Fictional Cafe"
    records = collector.read_rows(directory / "records.jsonl")
    assert records[0]["query"] == risky_query
    for record in records[:2]:
        assert record["effective_query"] is None and record["outcome"] == "unsafe_query"
        assert record["retrieval_provenance"]["diagnostic"] == "privacy_rejected"
        assert not record["cached"] and not record["retrieval_provenance"]["network_attempted"]
        assert (
            record["private_query_guard"]["version"]
            == collector.private_training_query_guard.VERSION
        )
    assert collector.collect(directory, 1, 60, search, clock)["lookups_this_run"] == 0


def test_private_guard_never_reads_notes_receipts_amount_or_account(snapshot):
    value = row("ordinary")
    value["input"].update(
        {
            "notes": "AB12CD34",
            "receipt_context": "AB12CD34",
            "account": "AB12CD34",
            "amount": "9999",
        }
    )
    directory, _ = snapshot([value], private=True)
    clock = Clock()
    search = Search(clock)
    assert collector.collect(directory, 1, 60, search, clock)["privacy_rejected_rows"] == 0
    assert search.calls[0][:2] == ("Fictional Cafe", "")


def test_public_policy_ignores_private_guard_and_writes_no_guard_sidecars(snapshot):
    directory, _ = snapshot([row("public", "AMZNMKTPL CA AB12CD34")])
    manifest_before = (directory / "manifest.json").read_bytes()
    clock = Clock()
    search = Search(clock)
    assert collector.collect(directory, 1, 60, search, clock)["lookups_this_run"] == 1
    assert search.calls[0][0] == "AMZNMKTPL CA AB12CD34"
    assert not list(directory.glob("private-*.json*"))
    assert (directory / "manifest.json").read_bytes() == manifest_before


def test_private_guard_preserves_historical_network_audit_and_only_gates_pending(snapshot):
    directory, _ = snapshot(
        [
            row("earlier", "AMZNMKTPL CA AB12CD34"),
            row("pending", "DIGITALBILL CA Z9YXW8V7"),
        ],
        private=True,
    )
    first = collector.read_rows(directory / "queries.jsonl")[0]
    record = {
        **first,
        "outcome": "no_match",
        "merchant_context": None,
        "cached": False,
        "retrieval_provenance": {"network_attempted": True},
    }
    path = collector.record_path(directory, first)
    collector.write_json(path, record, immutable=True)
    original = path.read_bytes()
    clock = Clock()
    search = Search(clock)
    result = collector.collect(directory, 1, 60, search, clock)
    assert path.read_bytes() == original
    assert not search.calls
    assert result["historical_records_before_privacy_guard"] == 1
    assert result["historical_network_attempts_now_privacy_rejected"] == 1
    assert result["completed"] == 2


def test_private_guard_source_version_and_effective_candidates_are_frozen(snapshot, monkeypatch):
    directory, _ = snapshot([row("ordinary")], private=True)
    clock = Clock()
    search = Search(clock)
    monkeypatch.setattr(collector.private_training_query_guard, "VERSION", "changed")
    with pytest.raises(ValueError, match="Frozen private query guard/candidates changed"):
        collector.collect(directory, 1, 60, search, clock)
    assert not search.calls


def make_legacy_collection(snapshot, monkeypatch, extra_rows=()):
    """Offline v1-policy records produced through the real collector/handle."""
    directory, source = snapshot(
        [
            row("past-mobi", "PRESTO MOBI ABCDEFGHIJ"),
            row("past-appl", "PRESTO APPL KLMNOPQRST TORONTO ON"),
            row("old-rejected", "Fictional Shop AB12CD34"),
            row("pending-mobi", "PRESTO MOBI UVWXYZABCD"),
            row("ordinary", "Fictional Cafe"),
        ]
        + list(extra_rows),
        private=True,
    )
    manifest, _, queries = collector.load(directory)
    candidates = collector.candidate_rows(
        queries, collector.private_training_query_guard.legacy_private_query_rejection
    )
    contents = collector.candidate_text(candidates)
    guard = {
        "version": collector.LEGACY_GUARD,
        "source_sha256": collector.sha256(
            Path(collector.private_training_query_guard.__file__).read_bytes()
        ),
        "frozen_queries_sha256": manifest["queries_sha256"],
        "effective_queries_sha256": collector.sha256(contents.encode()),
        "policy": collector.GUARD_POLICY,
    }
    collector.atomic_text(directory / "private-effective-queries.jsonl", contents)
    collector.write_json(directory / "private-query-guard.json", guard)
    clock = Clock()
    search = Search(clock, ("no_match", "no_match"))
    with monkeypatch.context() as old_policy:
        old_policy.setattr(
            collector.private_training_query_guard, "VERSION", collector.LEGACY_GUARD
        )
        old_policy.setattr(
            collector,
            "private_query_rejection",
            collector.private_training_query_guard.legacy_private_query_rejection,
        )
        result = collector.collect(directory, 2, 100, search, clock)
    assert result["completed"] == 3
    assert len(search.calls) == 2
    return directory, source, manifest, queries


@pytest.mark.parametrize("prefix", ["MOBI", "APPL"])
def test_v2_rejects_alphabetic_fare_references_only_under_provider_prefix(prefix):
    query = {"merchant": f"PRESTO {prefix} ABCDEFGHIJ TORONTO ON", "locality": ""}
    before = dict(query)
    assert collector.private_training_query_guard.legacy_private_query_rejection(query) is None
    assert collector.private_query_rejection(query) == "mobile_transit_alphabetic_reference"
    assert query == before
    assert (
        collector.private_query_rejection(
            {"merchant": "Fictional ABCDEFGHIJ Market", "locality": ""}
        )
        is None
    )


def test_migration_preserves_actual_old_record_bytes_and_never_retries_rejected_queries(
    snapshot, monkeypatch
):
    directory, source, manifest, queries = make_legacy_collection(snapshot, monkeypatch)
    frozen_before = {
        path: path.read_bytes()
        for path in (
            source,
            directory / "manifest.json",
            directory / "input.jsonl",
            directory / "queries.jsonl",
        )
    }
    old_records = {path: path.read_bytes() for path in (directory / "records").glob("*.json")}
    old_guard = (directory / "private-query-guard.json").read_bytes()
    old_candidates = (directory / "private-effective-queries.jsonl").read_bytes()
    with pytest.raises(ValueError, match="explicit migration"):
        collector.status(directory)
    collector.private_candidates(directory, manifest, queries, migrate=True)
    archive = directory / "private-query-guard-history" / collector.LEGACY_GUARD
    assert (archive / "private-query-guard.json").read_bytes() == old_guard
    assert (archive / "private-effective-queries.jsonl").read_bytes() == old_candidates
    assert all(path.read_bytes() == value for path, value in old_records.items())
    summary = collector.status(directory)
    assert summary["historical_network_attempts_now_privacy_rejected"] == 2
    assert summary["privacy_rejected_rows"] == 4
    clock, search_clock = Clock(), Clock()
    search = Search(search_clock)
    result = collector.collect(directory, 1, 100, search, clock)
    assert result["completed"] == 5
    assert [call[0] for call in search.calls] == ["Fictional Cafe"]
    pending_record = json.loads(
        collector.record_path(directory, {"id": "pending-mobi"}).read_text()
    )
    assert (
        pending_record["private_query_guard"]["version"]
        == collector.private_training_query_guard.VERSION
    )
    assert pending_record["effective_query"] is None
    assert pending_record["retrieval_provenance"]["network_attempted"] is False
    assert all(path.read_bytes() == value for path, value in old_records.items())
    assert all(path.read_bytes() == value for path, value in frozen_before.items())
    assert collector.collect(directory, 1, 100, search, clock)["lookups_this_run"] == 0
    before = {p: p.read_bytes() for p in directory.rglob("*") if p.is_file()}
    collector.private_candidates(directory, manifest, queries, migrate=True)
    assert all(p.read_bytes() == content for p, content in before.items())


@pytest.mark.parametrize(
    "stage",
    [
        "archive_guard",
        "archive_candidates",
        "record_hashes",
        "journal",
        "active_candidates",
        "active_guard",
    ],
)
def test_interrupted_private_guard_migration_recovers_only_explicitly(snapshot, monkeypatch, stage):
    directory, _, manifest, queries = make_legacy_collection(snapshot, monkeypatch)
    archive = directory / "private-query-guard-history" / collector.LEGACY_GUARD
    target = {
        "archive_guard": archive / "private-query-guard.json",
        "archive_candidates": archive / "private-effective-queries.jsonl",
        "record_hashes": archive / "record-hashes.json",
        "journal": directory / collector.MIGRATION_FILE,
        "active_candidates": directory / "private-effective-queries.jsonl",
        "active_guard": directory / "private-query-guard.json",
    }[stage]
    original = collector.atomic_text
    triggered = []

    def interrupt(path, text, immutable=False):
        original(path, text, immutable)
        if Path(path) == target and not triggered:
            triggered.append(True)
            raise RuntimeError("fictional interrupted atomic step")

    monkeypatch.setattr(collector, "atomic_text", interrupt)
    with pytest.raises(RuntimeError, match="interrupted atomic"):
        collector.private_candidates(directory, manifest, queries, migrate=True)
    assert triggered
    monkeypatch.setattr(collector, "atomic_text", original)
    if stage != "active_guard":
        with pytest.raises(ValueError, match="explicit migration"):
            collector.status(directory)
    collector.private_candidates(directory, manifest, queries, migrate=True)
    assert (
        collector.status(directory)["private_query_guard_version"]
        == collector.private_training_query_guard.VERSION
    )
    assert collector.status(directory)["historical_network_attempts_now_privacy_rejected"] == 2


def test_migration_refuses_old_effective_query_widening_even_with_self_consistent_hash(
    snapshot, monkeypatch
):
    directory, _, manifest, queries = make_legacy_collection(snapshot, monkeypatch)
    path = directory / "private-effective-queries.jsonl"
    rows = collector.read_rows(path)
    rows[0]["effective_query"] = {"merchant": "A changed public-looking query", "locality": ""}
    contents = "".join(collector.canonical(r) + "\n" for r in rows)
    collector.atomic_text(path, contents)
    guard = json.loads((directory / "private-query-guard.json").read_text())
    guard["effective_queries_sha256"] = collector.sha256(contents.encode())
    collector.write_json(directory / "private-query-guard.json", guard)
    with pytest.raises(ValueError, match="corrupt or widen"):
        collector.private_candidates(directory, manifest, queries, migrate=True)
    assert not (directory / collector.MIGRATION_FILE).exists()


@pytest.mark.parametrize("corruption", ["archive", "historical_record", "journal"])
def test_migrated_archive_and_historical_records_cannot_be_rewritten(
    snapshot, monkeypatch, corruption
):
    directory, _, manifest, queries = make_legacy_collection(snapshot, monkeypatch)
    collector.private_candidates(directory, manifest, queries, migrate=True)
    archive = directory / "private-query-guard-history" / collector.LEGACY_GUARD
    if corruption == "archive":
        path = archive / "private-query-guard.json"
    elif corruption == "historical_record":
        path = collector.record_path(directory, {"id": "past-mobi"})
    else:
        path = directory / collector.MIGRATION_FILE
    with path.open("a") as stream:
        stream.write(" ")
    # JSON whitespace still changes immutable byte identity in guard/record data.
    if corruption == "journal":
        value = json.loads(path.read_text())
        value["old_guard_sha256"] = "0" * 64
        collector.write_json(path, value)
    clock = Clock()
    search = Search(clock)
    with pytest.raises(ValueError, match="changed"):
        collector.collect(directory, 1, 100, search, clock)
    assert not search.calls


def test_historical_archive_is_loaded_once_per_validation_pass(snapshot, monkeypatch):
    directory, _, manifest, queries = make_legacy_collection(snapshot, monkeypatch)
    collector.private_candidates(directory, manifest, queries, migrate=True)
    candidates, guard = collector.private_candidates(directory, manifest, queries)
    done = collector.completed(directory, queries)
    calls, original = [], collector.version_bundle

    def counted(*args):
        calls.append(args[3])
        return original(*args)

    monkeypatch.setattr(collector, "version_bundle", counted)
    collector.validate_private_records(done, candidates, guard, directory)
    assert sorted(calls) == sorted([collector.LEGACY_GUARD, collector.V2_GUARD])


def test_migration_cannot_remove_old_rejections(snapshot, monkeypatch):
    directory, _, manifest, queries = make_legacy_collection(snapshot, monkeypatch)
    before = (directory / "private-query-guard.json").read_bytes()
    monkeypatch.setattr(collector, "private_query_rejection", lambda query: None)
    with pytest.raises(ValueError, match="may only add rejections"):
        collector.private_candidates(directory, manifest, queries, migrate=True)
    assert (directory / "private-query-guard.json").read_bytes() == before
    assert not (directory / collector.MIGRATION_FILE).exists()


def test_new_record_cannot_impersonate_pre_migration_guard_version(snapshot, monkeypatch):
    directory, _, manifest, queries = make_legacy_collection(snapshot, monkeypatch)
    collector.private_candidates(directory, manifest, queries, migrate=True)
    archive = directory / "private-query-guard-history" / collector.LEGACY_GUARD
    guard, candidates = collector.legacy_bundle(archive, manifest, queries)
    query = next(q for q in queries if q["id"] == "pending-mobi")
    record = {
        **query,
        "outcome": "no_match",
        "merchant_context": None,
        "cached": False,
        "private_query_guard": {**guard, "rejection": candidates[query["id"]]["rejection"]},
        "effective_query": query["query"],
        "retrieval_provenance": {"network_attempted": True},
    }
    collector.write_json(collector.record_path(directory, query), record, immutable=True)
    with pytest.raises(ValueError, match="Unregistered historical private guard record"):
        collector.status(directory)


@pytest.mark.parametrize(
    "merchant,reason",
    [
        ("PAYPAL Fictional Placeholder", "private_paypal_descriptor"),
        ("paypal*FictionalPlaceholder", "private_paypal_descriptor"),
        ("PAYPAL", "private_paypal_descriptor"),
        ("DR Fictional Placeholder", "personal_title_descriptor"),
        ("DR. Fictional Placeholder", "personal_title_descriptor"),
        ("Dr.Fictional Placeholder", "personal_title_descriptor"),
        ("DOCTOR Fictional Placeholder", "personal_title_descriptor"),
    ],
)
def test_v3_rejects_private_processor_and_personal_title_prefixes(merchant, reason):
    query = {"merchant": merchant, "locality": ""}
    before = dict(query)
    assert collector.private_training_query_guard.v2_private_query_rejection(query) is None
    assert collector.private_query_rejection(query) == reason
    assert query == before


@pytest.mark.parametrize(
    "merchant", ["Fictional PAYPAL Cafe", "DRAGON Cafe", "Doctoral Cafe", "MR Fictional Restaurant"]
)
def test_v3_prefix_rules_do_not_expand_to_unrelated_words(merchant):
    assert collector.private_query_rejection({"merchant": merchant, "locality": ""}) is None


@pytest.mark.parametrize("merchant", ["PAYPAL Fictional Placeholder", "DR. Fictional Placeholder"])
def test_v3_person_like_candidates_are_rejected_before_cache_or_network(snapshot, merchant):
    directory, _ = snapshot([row("fictional-private", merchant)], private=True)
    clock = Clock()
    query = {"merchant": merchant, "locality": ""}
    collector.write_json(
        directory / "state.json",
        {
            "not_before_ms": 0,
            "cache": {
                collector.cache_key(query): {
                    "evidence": {"outcome": "no_match", "context": None},
                    "fetched_at_ms": int(clock.time() * 1000),
                    "source_id": "earlier-fixture",
                }
            },
        },
    )
    search = Search(clock)
    result = collector.collect(directory, 1, 60, search, clock)
    assert result["completed"] == 1 and result["lookups_this_run"] == 0
    assert not search.calls
    record = collector.read_rows(directory / "records.jsonl")[0]
    assert record["query"] == query and record["effective_query"] is None
    assert not record["cached"] and not record["retrieval_provenance"]["network_attempted"]
    assert record["outcome"] == "unsafe_query"


def test_v3_private_rules_do_not_change_public_collection(snapshot):
    directory, _ = snapshot([row("fictional-public", "PAYPAL Fictional Placeholder")])
    source_bytes = (directory / "manifest.json").read_bytes()
    clock = Clock()
    search = Search(clock)
    assert collector.collect(directory, 1, 60, search, clock)["lookups_this_run"] == 1
    assert search.calls[0][0] == "PAYPAL Fictional Placeholder"
    assert not list(directory.glob("private-*.json*"))
    assert (directory / "manifest.json").read_bytes() == source_bytes


def make_v2_chain(snapshot, monkeypatch):
    directory, source, manifest, queries = make_legacy_collection(
        snapshot,
        monkeypatch,
        [
            row("old-paypal", "PAYPAL Fictional Earlier Placeholder"),
            row("old-doctor", "DR Fictional Earlier Placeholder"),
            row("pending-paypal", "PAYPAL Fictional Pending Placeholder"),
            row("pending-doctor", "DOCTOR Fictional Pending Placeholder"),
        ],
    )
    with monkeypatch.context() as v2:
        v2.setattr(collector.private_training_query_guard, "VERSION", collector.V2_GUARD)
        v2.setattr(
            collector,
            "private_query_rejection",
            collector.private_training_query_guard.v2_private_query_rejection,
        )
        collector.private_candidates(directory, manifest, queries, migrate=True)
        # Recreate the old deployed journal format. V3 must not upgrade/rewrite it.
        journal_path = directory / collector.MIGRATION_FILE
        legacy_journal = json.loads(journal_path.read_text())
        legacy_journal["format_version"] = 1
        legacy_journal.pop("new_guard")
        collector.write_json(journal_path, legacy_journal)
        clock = Clock()
        search = Search(clock, ("no_match", "no_match", "no_match"))
        result = collector.collect(directory, 3, 100, search, clock)
    assert result["completed"] == 7 and len(search.calls) == 3
    return directory, source, manifest, queries


def test_v1_v2_v3_chain_preserves_every_old_record_archive_and_manifest(snapshot, monkeypatch):
    directory, source, manifest, queries = make_v2_chain(snapshot, monkeypatch)
    protected_paths = [
        source,
        directory / "input.jsonl",
        directory / "queries.jsonl",
        directory / "manifest.json",
        directory / collector.MIGRATION_FILE,
        *(directory / "private-query-guard-history").rglob("*"),
        *(directory / "records").glob("*.json"),
    ]
    before = {p: p.read_bytes() for p in protected_paths if p.is_file()}
    old_active_guard = (directory / "private-query-guard.json").read_bytes()
    old_active_candidates = (directory / "private-effective-queries.jsonl").read_bytes()
    with pytest.raises(ValueError, match="explicit migration"):
        collector.status(directory)
    collector.private_candidates(directory, manifest, queries, migrate=True)
    archive = directory / "private-query-guard-history" / collector.V2_GUARD
    assert (archive / "private-query-guard.json").read_bytes() == old_active_guard
    assert (archive / "private-effective-queries.jsonl").read_bytes() == old_active_candidates
    assert (
        directory / collector.migration_file(collector.V2_GUARD, collector.CURRENT_MIGRATION_GUARD)
    ).is_file()
    assert all(path.read_bytes() == value for path, value in before.items())
    summary = collector.status(directory)
    assert summary["historical_network_attempts_now_privacy_rejected"] == 4
    assert summary["historical_network_attempts_now_privacy_rejected_by_guard_version"] == {
        collector.LEGACY_GUARD: 2,
        collector.V2_GUARD: 2,
    }
    assert summary["privacy_rejections_by_reason"]["private_paypal_descriptor"] == 2
    assert summary["privacy_rejections_by_reason"]["personal_title_descriptor"] == 2
    clock = Clock()
    search = Search(clock)
    resumed = collector.collect(directory, 1, 100, search, clock)
    assert resumed["completed"] == 9 and resumed["lookups_this_run"] == 0
    assert not search.calls
    assert all(path.read_bytes() == value for path, value in before.items())
    snapshot_bytes = {p: p.read_bytes() for p in directory.rglob("*") if p.is_file()}
    collector.private_candidates(directory, manifest, queries, migrate=True)
    assert all(p.read_bytes() == value for p, value in snapshot_bytes.items())


@pytest.mark.parametrize(
    "stage",
    [
        "archive_guard",
        "archive_candidates",
        "record_hashes",
        "journal",
        "active_candidates",
        "active_guard",
    ],
)
def test_v2_v3_interrupted_migration_preserves_prior_chain_and_recovers(
    snapshot, monkeypatch, stage
):
    directory, _, manifest, queries = make_v2_chain(snapshot, monkeypatch)
    old_journal = (directory / collector.MIGRATION_FILE).read_bytes()
    archive = directory / "private-query-guard-history" / collector.V2_GUARD
    target = {
        "archive_guard": archive / "private-query-guard.json",
        "archive_candidates": archive / "private-effective-queries.jsonl",
        "record_hashes": archive / "record-hashes.json",
        "journal": directory
        / collector.migration_file(collector.V2_GUARD, collector.CURRENT_MIGRATION_GUARD),
        "active_candidates": directory / "private-effective-queries.jsonl",
        "active_guard": directory / "private-query-guard.json",
    }[stage]
    original = collector.atomic_text
    triggered = []

    def interrupt(path, contents, immutable=False):
        original(path, contents, immutable)
        if Path(path) == target and not triggered:
            triggered.append(True)
            raise RuntimeError("fictional v2-v3 interruption")

    monkeypatch.setattr(collector, "atomic_text", interrupt)
    with pytest.raises(RuntimeError, match="v2-v3 interruption"):
        collector.private_candidates(directory, manifest, queries, migrate=True)
    monkeypatch.setattr(collector, "atomic_text", original)
    if stage != "active_guard":
        with pytest.raises(ValueError, match="explicit migration"):
            collector.status(directory)
    collector.private_candidates(directory, manifest, queries, migrate=True)
    assert collector.status(directory)["historical_network_attempts_now_privacy_rejected"] == 4
    assert (directory / collector.MIGRATION_FILE).read_bytes() == old_journal
