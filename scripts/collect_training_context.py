"""Freeze and resume real production DuckDuckGo evidence for training inputs.

No labels or classifier predictions are produced. ``prepare`` runs the actual
Swift MerchantQueryPilot (description fallback, empty locality), or the distinct
MerchantTrainingQueryPilot with --ledger-query for frozen merchant/locality; only its public
merchant/locality projection can reach MerchantSearch.handle. Source input is
never sent to a search engine. Results are immutable per-row files; records.jsonl
and summary.json are replaceable exports. Use an ignored .private directory for
private inputs. Collection is deliberately serial and bounded on every run.
Private collections also reject reference-like residual candidates under a
separately versioned privacy guard. This additional policy never rewrites a
query and does not change the production sanitizer or historical records.
"""

import argparse
import fcntl
import hashlib
import json
import os
import subprocess
import tempfile
import time
from collections import Counter
from contextlib import contextmanager
from datetime import datetime, timezone
from importlib.metadata import version
from pathlib import Path

from groundkeeper.merchant_context import validate_context
from groundkeeper.merchant_search import GAP_SECONDS, MerchantSearch
from scripts import private_training_query_guard
from scripts.private_training_query_guard import private_query_rejection

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "apps/macos/GroundKeeperCore"
SOURCES = (
    "apps/macos/GroundKeeperCore/Sources/MerchantQueryPilot/main.swift",
    "apps/macos/GroundKeeperCore/Sources/GroundKeeperCore/MerchantSearch.swift",
    "apps/macos/GroundKeeper/Services/MerchantWorkspace.swift",
    "groundkeeper/merchant_search.py",
    "groundkeeper/merchant_context.py",
)
LEDGER_SOURCES = (
    "apps/macos/GroundKeeperCore/Sources/MerchantTrainingQueryPilot/main.swift",
    "apps/macos/GroundKeeperCore/Package.swift",
    *SOURCES[1:],
)
TTL_MS = {"matched": 2_592_000_000, "no_match": 86_400_000}
DELAY_MS = {"blocked": 900_000, "unavailable": 60_000}


def canonical(value):
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    )


def sha256(value):
    return hashlib.sha256(value).hexdigest()


def input_hash(value):
    return sha256(canonical(value).encode())


def read_rows(path):
    return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]


def now_ms():
    return time.time_ns() // 1_000_000


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def atomic_text(path, text, immutable=False):
    """Publish a fully fsynced file; immutable records never replace an old file."""
    path = Path(path)
    handle, temporary = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if immutable:
            os.link(temporary, path)
        else:
            os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(path, value, immutable=False):
    atomic_text(path, canonical(value) + "\n", immutable)


def ignored_output(path):
    path = Path(path).resolve()
    relative = path.relative_to(ROOT)
    if not relative.parts or relative.parts[0] not in (".local", ".private"):
        raise ValueError("Output must be under the repository's ignored .local/ or .private/")
    if subprocess.run(
        ["git", "check-ignore", "-q", str(relative)], cwd=ROOT, check=False
    ).returncode:
        raise ValueError("Output directory must be ignored by Git")
    return path


@contextmanager
def exclusive(directory):
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / ".collector.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Another collector owns this output directory") from error
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def validate_rows(rows):
    ids = set()
    if not rows:
        raise ValueError("Input must contain at least one row")
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str) or not row["id"]:
            raise ValueError("Each row needs a nonempty opaque string id")
        if row["id"] in ids:
            raise ValueError("Input IDs must be unique")
        ids.add(row["id"])
        value = row.get("input")
        if not isinstance(value, dict) or not isinstance(value.get("description"), str):
            raise ValueError("Each row needs an input object with a description string")
        if "merchant_context" in value:
            raise ValueError("Freeze baseline inputs without existing merchant_context")


def project(rows, ledger_query=False):
    """Compile current Swift source; never accept unverified external projections."""
    # The subprocess sees only an opaque ID and the actual make() arguments.
    # Amounts, notes, receipts and account fields never enter query construction.
    projection_inputs = []
    for row in rows:
        item = {"id": row["id"], "input": {"description": row["input"]["description"]}}
        if ledger_query:
            for field in ("search_merchant", "search_locality"):
                value = row.get(field)
                if value is not None and not isinstance(value, str):
                    raise ValueError("Frozen merchant/locality must be strings or null")
                item[field] = value
        projection_inputs.append(item)
    pilot = "MerchantTrainingQueryPilot" if ledger_query else "MerchantQueryPilot"
    temporary_root = ROOT / (".private" if ledger_query else ".local")
    temporary_root.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="gk-query-", dir=temporary_root) as directory:
        source = Path(directory) / "input.jsonl"
        source.write_text("".join(canonical(item) + "\n" for item in projection_inputs))
        result = subprocess.run(
            ["swift", "run", "--package-path", str(PACKAGE), pilot, str(source)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=True,
            timeout=300,
        )
    projected = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
    if [row["id"] for row in projected] != [row["id"] for row in rows]:
        raise ValueError("Swift projection IDs changed")
    for row in projected:
        # Swift encodes nil optional query by omitting the key.
        row.setdefault("query", None)
        if row["query"] is not None and set(row["query"]) != {"merchant", "locality"}:
            raise ValueError("Unexpected Swift query projection")
    return projected


def source_hashes(paths=None):
    paths = SOURCES if paths is None else paths
    for path in paths:
        (ROOT / path).resolve().relative_to(ROOT.resolve())
    return {path: sha256((ROOT / path).read_bytes()) for path in paths}


def prepare(directory, source, private=False, ledger_query=False):
    rows = read_rows(source)
    validate_rows(rows)
    if private and directory.relative_to(ROOT).parts[0] != ".private":
        raise ValueError("Private inputs must use an ignored .private/ output directory")
    if (directory / "manifest.json").exists():
        manifest, existing, _ = load(directory)
        if (
            canonical(existing) != canonical(rows)
            or manifest["private"] != private
            or manifest.get("ledger_query", False) != ledger_query
        ):
            raise ValueError("Frozen inputs changed; use a new collection directory")
        return status(directory)
    if list(directory.glob("*.json*")) or (directory / "records").exists():
        raise ValueError("Incomplete preparation: use a new empty collection directory")
    (ROOT / ".local").mkdir(exist_ok=True)
    projected = project(rows, ledger_query=ledger_query)
    # Preserve source/split/family metadata too: it is part of the frozen source,
    # but never part of the subprocess or network projection.
    inputs = "".join(canonical(row) + "\n" for row in rows)
    queries = "".join(
        canonical({**row, "input_sha256": input_hash(value["input"])}) + "\n"
        for value, row in zip(rows, projected)
    )
    # Manifest is committed last. A partially prepared directory is never resumed.
    atomic_text(directory / "input.jsonl", inputs, immutable=True)
    atomic_text(directory / "queries.jsonl", queries, immutable=True)
    (directory / "records").mkdir()
    manifest = {
        "schema_version": 1,
        "created_at": timestamp(),
        "private": private,
        "row_count": len(rows),
        "input_sha256": sha256(inputs.encode()),
        "queries_sha256": sha256(queries.encode()),
        "source_sha256": source_hashes(LEDGER_SOURCES if ledger_query else SOURCES),
        "ledger_query": ledger_query,
        "query_builder": "GroundKeeperCore.MerchantSearchQuery.make",
        "query_projection": (
            "MerchantTrainingQueryPilot: frozen search_merchant/search_locality, exact description fallback"
            if ledger_query
            else "MerchantQueryPilot: description fallback, merchant=nil, locality=empty"
        ),
        "retrieval": "groundkeeper.merchant_search.MerchantSearch.handle",
        "engine": "duckduckgo",
        "region": "ca-en",
        "max_results": 5,
        "max_context_results": 2,
        "max_context_bytes": 1500,
        "gap_after_completion_seconds": GAP_SECONDS,
        "cache_ttl_ms": TTL_MS,
        "cache_capacity": 1000,
        "failure_delay_ms": DELAY_MS,
        "inflight_reservation_ms": 45_000,
        "network_fields": ["query.merchant", "query.locality"],
        "synthetic_context": False,
    }
    write_json(directory / "manifest.json", manifest, immutable=True)
    return status(directory)


def record_path(directory, row):
    return directory / "records" / (sha256(row["id"].encode()) + ".json")


def load(directory):
    manifest = json.loads((directory / "manifest.json").read_text())
    for filename, key in (("input.jsonl", "input_sha256"), ("queries.jsonl", "queries_sha256")):
        if sha256((directory / filename).read_bytes()) != manifest[key]:
            raise ValueError("Frozen input/query file changed")
    # Each frozen collection owns its source list. Adding a distinct projection
    # target must not invalidate a live legacy public collection.
    if manifest["source_sha256"] != source_hashes(manifest["source_sha256"]):
        raise ValueError("Production retrieval/sanitizer source changed; use a new collection")
    rows, queries = read_rows(directory / "input.jsonl"), read_rows(directory / "queries.jsonl")
    validate_rows(rows)
    if len(rows) != manifest["row_count"] or len(queries) != len(rows):
        raise ValueError("Frozen row counts changed")
    for row, query in zip(rows, queries):
        if row["id"] != query["id"] or input_hash(row["input"]) != query["input_sha256"]:
            raise ValueError("Query/input hashes do not align")
    return manifest, rows, queries


def completed(directory, queries):
    result = {}
    expected_paths = {record_path(directory, query) for query in queries}
    if any(path not in expected_paths for path in (directory / "records").glob("*.json")):
        raise ValueError("Unexpected completed record")
    for query in queries:
        path = record_path(directory, query)
        if path.exists():
            value = json.loads(path.read_text())
            if any(value.get(key) != query.get(key) for key in ("id", "input_sha256", "query")):
                raise ValueError("Completed record does not match frozen input/query")
            validate_evidence({"outcome": value["outcome"], "context": value["merchant_context"]})
            result[query["id"]] = value
    return result


def cache_key(query):
    # Same contentHash string as MerchantSearchQuery.cacheKey in Swift.
    return sha256(
        (
            "merchant-search-v1|" + query["merchant"].lower() + "|" + query["locality"].lower()
        ).encode()
    )


def validate_evidence(evidence):
    outcome, context = evidence.get("outcome"), evidence.get("context")
    if outcome not in ("matched", "no_match", "unsafe_query", "backoff", "blocked", "unavailable"):
        raise ValueError("Unknown search outcome")
    if (outcome == "matched") != (context is not None):
        raise ValueError("Search outcome does not match context")
    if context is not None:
        validate_context(context)


def load_state(directory):
    path = directory / "state.json"
    state = json.loads(path.read_text()) if path.exists() else {"not_before_ms": 0, "cache": {}}
    if (
        not isinstance(state, dict)
        or set(state) != {"not_before_ms", "cache"}
        or type(state["not_before_ms"]) is not int
        or state["not_before_ms"] < 0
        or not isinstance(state["cache"], dict)
    ):
        raise ValueError("Invalid persisted collection state")
    for key, item in state["cache"].items():
        if (
            not isinstance(key, str)
            or len(key) != 64
            or not isinstance(item, dict)
            or set(item) != {"evidence", "fetched_at_ms", "source_id"}
            or type(item["fetched_at_ms"]) is not int
            or item["fetched_at_ms"] < 0
            or not isinstance(item["source_id"], str)
        ):
            raise ValueError("Invalid persisted search cache")
        validate_evidence(item["evidence"])
        if item["evidence"]["outcome"] not in TTL_MS:
            raise ValueError("Only matched/no_match outcomes may be cached")
    return state


def prune_cache(state, current):
    cache = state["cache"]
    for key in list(cache):
        item = cache[key]
        validate_evidence(item["evidence"])
        ttl = TTL_MS[item["evidence"]["outcome"]]
        if item["fetched_at_ms"] + ttl <= current:
            del cache[key]
    for key in sorted(cache, key=lambda k: cache[k]["fetched_at_ms"], reverse=True)[1000:]:
        del cache[key]


GUARD_POLICY = "private collection privacy guard; distinct from production sanitizer/matcher"
LEGACY_GUARD = "private-training-query-v1"
V2_GUARD = "private-training-query-v2"
CURRENT_MIGRATION_GUARD = "private-training-query-v3"
GUARD_VERSIONS = (LEGACY_GUARD, V2_GUARD, CURRENT_MIGRATION_GUARD)
# Keep the existing v1->v2 journal name and contents intact.
MIGRATION_FILE = "private-query-guard-migration-v1-v2.json"


def migration_file(previous, target):
    if (previous, target) not in tuple(zip(GUARD_VERSIONS, GUARD_VERSIONS[1:])):
        raise ValueError("Unsupported private guard migration transition")
    return (
        "private-query-guard-migration-"
        + previous.rsplit("-", 1)[1]
        + "-"
        + target.rsplit("-", 1)[1]
        + ".json"
    )


def version_policy(version):
    policies = {
        LEGACY_GUARD: private_training_query_guard.legacy_private_query_rejection,
        V2_GUARD: private_training_query_guard.v2_private_query_rejection,
        CURRENT_MIGRATION_GUARD: private_training_query_guard.private_query_rejection,
    }
    if version not in policies:
        raise ValueError("Unknown private guard version")
    return policies[version]


def candidate_rows(queries, rejection_policy):
    candidates = {}
    for row in queries:
        if row["id"] in candidates:
            raise ValueError("Duplicate frozen private query ID")
        rejection = rejection_policy(row["query"])
        candidates[row["id"]] = {
            "id": row["id"],
            "input_sha256": row["input_sha256"],
            "frozen_query_sha256": input_hash(row["query"]),
            "effective_query": None if rejection else row["query"],
            "rejection": rejection,
        }
    return candidates


def candidate_text(candidates):
    return "".join(canonical(value) + "\n" for value in candidates.values())


def guard_provenance(version, manifest, contents):
    return {
        "version": version,
        "source_sha256": sha256(Path(private_training_query_guard.__file__).read_bytes()),
        "frozen_queries_sha256": manifest["queries_sha256"],
        "effective_queries_sha256": sha256(contents.encode()),
        "policy": GUARD_POLICY,
    }


def version_bundle(directory, manifest, queries, version):
    """Reconstruct one immutable policy version once per validation pass."""
    guard = json.loads((directory / "private-query-guard.json").read_text())
    expected = candidate_rows(queries, version_policy(version))
    expected_text = candidate_text(expected)
    if (
        set(guard)
        != {
            "version",
            "policy",
            "source_sha256",
            "frozen_queries_sha256",
            "effective_queries_sha256",
        }
        or guard.get("version") != version
        or guard.get("policy") != GUARD_POLICY
        or guard.get("frozen_queries_sha256") != manifest["queries_sha256"]
        or not isinstance(guard.get("source_sha256"), str)
        or len(guard["source_sha256"]) != 64
        or any(c not in "0123456789abcdef" for c in guard["source_sha256"])
        or guard.get("effective_queries_sha256") != sha256(expected_text.encode())
        or (directory / "private-effective-queries.jsonl").read_text() != expected_text
    ):
        raise ValueError("Historical private guard/candidates are corrupt or widen frozen queries")
    return guard, expected


def legacy_bundle(directory, manifest, queries):
    return version_bundle(directory, manifest, queries, LEGACY_GUARD)


def migration_history(directory, manifest, queries, guard, candidates, ignore_archive=None):
    """Validate the whole chain with one bundle read per archived version.

    Old format-1 v1->v2 journals are verified against the archived v2 successor.
    New format-2 journals also carry their exact target metadata for recovery.
    All historical record byte hashes are checked once, even across snapshots.
    """
    versions = {guard["version"]: (guard, candidates)}
    archives, snapshots = {}, {}
    history = directory / "private-query-guard-history"
    for archive in sorted(history.iterdir()) if history.exists() else ():
        if archive.name == ignore_archive:
            continue
        if not archive.is_dir() or archive.name not in GUARD_VERSIONS[:-1]:
            raise ValueError("Unknown private guard archive")
        versions[archive.name] = version_bundle(archive, manifest, queries, archive.name)
        archives[archive.name] = archive
    expected_journals = {migration_file(a, b) for a, b in zip(GUARD_VERSIONS, GUARD_VERSIONS[1:])}
    present_journals = {p.name for p in directory.glob("private-query-guard-migration-*.json")}
    if present_journals - expected_journals:
        raise ValueError("Unknown private guard migration journal")
    expected_names = {record_path(directory, q).name for q in queries}
    checked_hashes = {}
    for previous, target in zip(GUARD_VERSIONS, GUARD_VERSIONS[1:]):
        name = migration_file(previous, target)
        if previous not in archives:
            if name in present_journals:
                raise ValueError("Private guard migration journal has no immutable archive")
            continue
        archive = archives[previous]
        path = directory / name
        if not path.exists() or target not in versions:
            raise ValueError("Private guard archive exists without a complete migration chain")
        journal_text = path.read_text()
        journal = json.loads(journal_text)
        old_guard, _ = versions[previous]
        target_guard, target_candidates = versions[target]
        hashes_path = archive / "record-hashes.json"
        if (
            journal_text != canonical(journal) + "\n"
            or journal.get("format_version") not in (1, 2)
            or journal.get("from_version") != previous
            or journal.get("to_version") != target
            or journal.get("frozen_queries_sha256") != manifest["queries_sha256"]
            or journal.get("old_guard_sha256")
            != sha256((archive / "private-query-guard.json").read_bytes())
            or journal.get("old_candidates_sha256")
            != sha256((archive / "private-effective-queries.jsonl").read_bytes())
            or journal.get("old_record_hashes_sha256") != sha256(hashes_path.read_bytes())
            or journal.get("new_guard_sha256") != sha256((canonical(target_guard) + "\n").encode())
            or journal.get("new_candidates_sha256")
            != sha256(candidate_text(target_candidates).encode())
            or (journal["format_version"] == 2 and journal.get("new_guard") != target_guard)
        ):
            raise ValueError("Private guard migration journal/archive changed")
        record_hashes = json.loads(hashes_path.read_text())
        if (
            not isinstance(record_hashes, dict)
            or set(record_hashes) - expected_names
            or any(not isinstance(v, str) or len(v) != 64 for v in record_hashes.values())
        ):
            raise ValueError("Invalid immutable historical record hashes")
        for filename, expected in record_hashes.items():
            record = directory / "records" / filename
            if filename not in checked_hashes:
                if not record.is_file():
                    raise ValueError("Immutable historical private record changed or disappeared")
                checked_hashes[filename] = sha256(record.read_bytes())
            if checked_hashes[filename] != expected:
                raise ValueError("Immutable historical private record changed or disappeared")
        snapshots[previous] = set(record_hashes)
    return versions, snapshots


def assert_only_restricts(previous, current):
    if set(previous) != set(current) or any(
        old["input_sha256"] != current[i]["input_sha256"]
        or old["frozen_query_sha256"] != current[i]["frozen_query_sha256"]
        or (old["rejection"] and old != current[i])
        for i, old in previous.items()
    ):
        raise ValueError("Private guard migration may only add rejections")


def migrate_step(directory, manifest, queries, previous, target, candidates, provenance):
    contents = candidate_text(candidates)
    guard_path, effective_path = (
        directory / "private-query-guard.json",
        directory / "private-effective-queries.jsonl",
    )
    archive = directory / "private-query-guard-history" / previous
    journal_path = directory / migration_file(previous, target)
    if not journal_path.exists():
        old_guard, old_candidates = version_bundle(directory, manifest, queries, previous)
        assert_only_restricts(old_candidates, candidates)
        done = completed(directory, queries)
        validate_private_records(
            done, old_candidates, old_guard, directory, ignore_archive=previous
        )
        snapshot = {
            record_path(directory, record).name: sha256(record_path(directory, record).read_bytes())
            for record in done.values()
        }
        archive.mkdir(parents=True, exist_ok=True)
        for original in (guard_path, effective_path):
            backup = archive / original.name
            if backup.exists() and backup.read_bytes() != original.read_bytes():
                raise ValueError("Private guard migration archive changed")
            if not backup.exists():
                atomic_text(backup, original.read_bytes().decode("utf-8"), immutable=True)
        hashes_path = archive / "record-hashes.json"
        if hashes_path.exists():
            if hashes_path.read_text() != canonical(snapshot) + "\n":
                raise ValueError("Historical records changed during interrupted migration")
        else:
            write_json(hashes_path, snapshot, immutable=True)
        journal = {
            "format_version": 2,
            "from_version": previous,
            "to_version": target,
            "frozen_queries_sha256": manifest["queries_sha256"],
            "old_guard_sha256": sha256(guard_path.read_bytes()),
            "old_candidates_sha256": sha256(effective_path.read_bytes()),
            "old_record_hashes_sha256": sha256(hashes_path.read_bytes()),
            "new_guard_sha256": sha256((canonical(provenance) + "\n").encode()),
            "new_candidates_sha256": sha256(contents.encode()),
            "new_guard": provenance,
        }
        write_json(journal_path, journal, immutable=True)
    migration_history(directory, manifest, queries, provenance, candidates)
    journal = json.loads(journal_path.read_text())
    state = sha256(guard_path.read_bytes()), sha256(effective_path.read_bytes())
    old = journal["old_guard_sha256"], journal["old_candidates_sha256"]
    new = journal["new_guard_sha256"], journal["new_candidates_sha256"]
    if state not in (old, (old[0], new[1]), new):
        raise ValueError("Private guard migration has an unsupported/corrupt active state")
    if state[1] != new[1]:
        atomic_text(effective_path, contents)
    if state[0] != new[0]:
        write_json(guard_path, provenance)


def migrate_guard(directory, manifest, queries, candidates, provenance):
    """Explicitly advance adjacent versions; never rewrite older chain artifacts."""
    active_path = directory / "private-query-guard.json"
    active = json.loads(active_path.read_text())
    target_version = provenance["version"]
    if active.get("version") not in GUARD_VERSIONS or target_version not in GUARD_VERSIONS:
        raise ValueError("Unknown private guard migration version")
    index, target_index = (
        GUARD_VERSIONS.index(active["version"]),
        GUARD_VERSIONS.index(target_version),
    )
    if index >= target_index:
        # The only supported same-version mismatch is a journaled interrupted write.
        if index == 0:
            raise ValueError("Private guard source/candidates changed without a new policy version")
        migrate_step(
            directory,
            manifest,
            queries,
            GUARD_VERSIONS[index - 1],
            target_version,
            candidates,
            provenance,
        )
        return
    # Fail before changing any state if the final target would relax old rejections.
    old_candidates = candidate_rows(queries, version_policy(active["version"]))
    assert_only_restricts(old_candidates, candidates)
    for target in GUARD_VERSIONS[index + 1 : target_index + 1]:
        previous = GUARD_VERSIONS[GUARD_VERSIONS.index(target) - 1]
        next_candidates = (
            candidates
            if target == target_version
            else candidate_rows(queries, version_policy(target))
        )
        next_guard = (
            provenance
            if target == target_version
            else guard_provenance(target, manifest, candidate_text(next_candidates))
        )
        migrate_step(directory, manifest, queries, previous, target, next_candidates, next_guard)


def private_candidates(directory, manifest, queries, migrate=False):
    """Gate future dispatch separately from immutable production snapshots."""
    if not manifest["private"]:
        return {}, None
    candidates = candidate_rows(queries, private_query_rejection)
    contents = candidate_text(candidates)
    provenance = guard_provenance(private_training_query_guard.VERSION, manifest, contents)
    path, effective_path = (
        directory / "private-query-guard.json",
        directory / "private-effective-queries.jsonl",
    )
    matches = (
        path.exists()
        and path.read_text() == canonical(provenance) + "\n"
        and effective_path.exists()
        and effective_path.read_text() == contents
    )
    has_history = (directory / "private-query-guard-history").exists()
    has_journal = bool(list(directory.glob("private-query-guard-migration-*.json")))
    if matches:
        migration_history(directory, manifest, queries, provenance, candidates)
    elif path.exists() or has_history or has_journal:
        if not migrate:
            raise ValueError(
                "Frozen private query guard/candidates changed; explicit migration required"
            )
        migrate_guard(directory, manifest, queries, candidates, provenance)
    else:
        if effective_path.exists() and effective_path.read_text() != contents:
            raise ValueError("Incomplete private query guard preparation changed")
        if not effective_path.exists():
            atomic_text(effective_path, contents, immutable=True)
        write_json(path, provenance, immutable=True)
    return candidates, provenance


def validate_private_records(done, candidates, guard, directory, ignore_archive=None):
    if not guard:
        return
    manifest, _, queries = load(directory)
    versions, snapshots = migration_history(
        directory, manifest, queries, guard, candidates, ignore_archive
    )
    historical_names = set().union(*snapshots.values()) if snapshots else None
    for identifier, record in done.items():
        name = record_path(directory, record).name
        if "private_query_guard" not in record:
            if historical_names is not None and name not in historical_names:
                raise ValueError("Unregistered guard-free historical private record")
            continue
        if not isinstance(record["private_query_guard"], dict):
            raise ValueError("Invalid historical private guard record metadata")
        record_version = record["private_query_guard"].get("version")
        if record_version not in versions:
            raise ValueError("Unknown/unarchived historical private guard version")
        if record_version != guard["version"] and name not in snapshots.get(record_version, set()):
            raise ValueError("Unregistered historical private guard record")
        record_guard, record_candidates = versions[record_version]
        candidate = record_candidates[identifier]
        if (
            record["private_query_guard"] != {**record_guard, "rejection": candidate["rejection"]}
            or record.get("effective_query") != candidate["effective_query"]
        ):
            raise ValueError("Completed private record does not match frozen privacy guard")
        if candidate["rejection"] and (
            record["outcome"] != "unsafe_query"
            or record["cached"]
            or record["retrieval_provenance"]["network_attempted"]
            or record["retrieval_provenance"].get("diagnostic") != "privacy_rejected"
        ):
            raise ValueError("Privacy-rejected record cannot contain retrieved evidence")


def status(directory, stop_reason=None):
    manifest, _, queries = load(directory)
    done = completed(directory, queries)
    candidates, guard = private_candidates(directory, manifest, queries)
    validate_private_records(done, candidates, guard, directory)
    state = load_state(directory)
    prune_cache(state, now_ms())
    pending = [row for row in queries if row["id"] not in done]
    effective = [
        candidates[row["id"]]["effective_query"] if guard else row["query"] for row in pending
    ]
    unique = {cache_key(query) for query in effective if query is not None}
    misses = unique - set(state["cache"])
    result = {
        "rows": manifest["row_count"],
        "completed": len(done),
        "pending": len(pending),
        "outcomes": dict(Counter(row["outcome"] for row in done.values())),
        "cache_rows": sum(row["cached"] for row in done.values()),
        "pending_unique_safe_queries": len(unique),
        "estimated_new_lookups": len(misses),
        "minimum_spacing_seconds": max(0, len(misses) - 1) * GAP_SECONDS,
        "not_before_ms": state["not_before_ms"],
        "stop_reason": stop_reason,
    }
    if guard:
        result.update(
            {
                "private_query_guard_version": guard["version"],
                "privacy_rejected_rows": sum(
                    bool(value["rejection"]) for value in candidates.values()
                ),
                "privacy_rejections_by_reason": dict(
                    Counter(
                        value["rejection"] for value in candidates.values() if value["rejection"]
                    )
                ),
                "pending_privacy_rejected_rows": sum(
                    bool(candidates[row["id"]]["rejection"]) for row in pending
                ),
                "historical_records_before_privacy_guard": sum(
                    "private_query_guard" not in row for row in done.values()
                ),
                "historical_network_attempts_now_privacy_rejected": sum(
                    bool(candidates[row["id"]]["rejection"])
                    and row["retrieval_provenance"]["network_attempted"]
                    for row in done.values()
                ),
                "historical_network_attempts_now_privacy_rejected_by_guard_version": dict(
                    Counter(
                        row.get("private_query_guard", {}).get("version", "before_private_guard")
                        for row in done.values()
                        if candidates[row["id"]]["rejection"]
                        and row["retrieval_provenance"]["network_attempted"]
                    )
                ),
            }
        )
    # Export in frozen source order, irrespective of crashes or collection batch size.
    atomic_text(
        directory / "records.jsonl",
        "".join(canonical(done[row["id"]]) + "\n" for row in queries if row["id"] in done),
    )
    write_json(directory / "summary.json", result)
    return result


def collect(directory, max_lookups, max_seconds, search=None, clock=None):
    """Run at most the given lookups/time; persistent backoff never gets reset."""
    if max_lookups < 1 or max_seconds <= 0:
        raise ValueError("Positive --max-lookups and --max-seconds are required")
    clock = clock or time
    search = search or MerchantSearch()
    manifest, _, queries = load(directory)
    done = completed(directory, queries)
    candidates, guard = private_candidates(directory, manifest, queries)
    validate_private_records(done, candidates, guard, directory)
    state = load_state(directory)
    started = clock.monotonic()
    attempts = 0
    reason = "complete"
    try:
        for row in queries:
            if row["id"] in done:
                continue
            if clock.monotonic() - started >= max_seconds:
                reason = "runtime_limit"
                break
            current = int(clock.time() * 1000)
            prune_cache(state, current)
            candidate = candidates[row["id"]] if guard else None
            query = candidate["effective_query"] if candidate else row["query"]
            key = cache_key(query) if query is not None else None
            cached = query is not None and key in state["cache"]
            elapsed = 0.0
            fetched_at = current
            cache_source = None
            if query is None:
                evidence = {"outcome": "unsafe_query", "context": None}
                if candidate and candidate["rejection"]:
                    evidence["diagnostic"] = "privacy_rejected"
            elif cached:
                item = state["cache"][key]
                evidence = item["evidence"]
                fetched_at, cache_source = item["fetched_at_ms"], item["source_id"]
            elif state["not_before_ms"] - current > 30_000:
                # The app binds baseline evidence during a long pause. An offline
                # collection instead stops here, retaining unresolved rows for a
                # later explicitly bounded run after the same production delay.
                reason = "backoff"
                break
            else:
                if attempts >= max_lookups:
                    reason = "lookup_limit"
                    break
                wait = max(0, (state["not_before_ms"] - current) / 1000)
                if clock.monotonic() - started + wait >= max_seconds:
                    reason = "runtime_limit"
                    break
                if wait:
                    clock.sleep(wait)
                # Persist the app's conservative pre-dispatch reservation. If the
                # process dies, a second run cannot immediately issue a new query.
                state["not_before_ms"] = int(clock.time() * 1000) + 45_000
                write_json(directory / "state.json", state)
                before = clock.monotonic()
                response = search.handle(
                    {
                        "protocol_version": 1,
                        "request_id": "training-context",
                        "operation": "merchant_search",
                        **query,
                    },
                    cancelled=lambda: clock.monotonic() - started >= max_seconds,
                )
                elapsed = clock.monotonic() - before
                attempts += 1
                if response.get("status") == "succeeded":
                    evidence = response["result"]
                elif response.get("error", {}).get("code") == "cancelled":
                    reason = "runtime_limit"
                    break
                else:
                    evidence = {
                        "outcome": "unavailable",
                        "context": None,
                        "diagnostic": response.get("error", {}).get("code", "search_unavailable"),
                    }
                validate_evidence(evidence)
                fetched_at = int(clock.time() * 1000)
                state["not_before_ms"] = fetched_at + DELAY_MS.get(evidence["outcome"], 10_500)
                if evidence["outcome"] in TTL_MS:
                    state["cache"][key] = {
                        "evidence": evidence,
                        "fetched_at_ms": fetched_at,
                        "source_id": row["id"],
                    }
                    prune_cache(state, fetched_at)
                write_json(directory / "state.json", state)
            validate_evidence(evidence)
            record = {
                **row,
                "query_status": "safe" if query is not None else "unsafe_query",
                "merchant_context": evidence.get("context"),
                "outcome": evidence["outcome"],
                "merchant_context_status": evidence["outcome"],
                "cached": cached,
                "retrieval_provenance": {
                    "engine": "duckduckgo",
                    "region": "ca-en",
                    "max_results": 5,
                    "query_builder": manifest["query_builder"],
                    "retrieval": manifest["retrieval"],
                    "source_sha256": manifest["source_sha256"],
                    "fetched_at_ms": fetched_at,
                    "recorded_at": timestamp(),
                    "cache_source_id": cache_source,
                    "lookup_wall_seconds_including_queue_wait": elapsed,
                    "network_attempted": query is not None
                    and not cached
                    and evidence["outcome"] != "backoff",
                    "diagnostic": evidence.get("diagnostic"),
                },
            }
            if guard:
                record["effective_query"] = query
                record["private_query_guard"] = {**guard, "rejection": candidate["rejection"]}
            write_json(record_path(directory, row), record, immutable=True)
            done[row["id"]] = record
            print(
                canonical(
                    {
                        "completed": len(done),
                        "total": len(queries),
                        "lookups_this_run": attempts,
                        "outcome": evidence["outcome"],
                    }
                ),
                flush=True,
            )
            if evidence["outcome"] in ("blocked", "unavailable"):
                # Stop the batch on provider failure. Resume respects the stored
                # production backoff; no alternate endpoint/engine is attempted.
                reason = "provider_" + evidence["outcome"]
                break
    except KeyboardInterrupt:
        reason = "interrupted"
    finally:
        result = status(directory, reason)
    result["lookups_this_run"] = attempts
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser(
        "prepare", help="freeze inputs and actual Swift query projections; no network"
    )
    prepare_parser.add_argument("--input", type=Path, required=True)
    prepare_parser.add_argument("--private", action="store_true")
    prepare_parser.add_argument(
        "--ledger-query",
        action="store_true",
        help="use frozen search_merchant/search_locality with exact description fallback",
    )
    for command in (
        prepare_parser,
        subparsers.add_parser("status"),
        subparsers.add_parser("collect"),
        subparsers.add_parser("migrate-private-guard"),
    ):
        command.add_argument("--output-dir", type=Path, required=True)
        if command.prog.endswith("collect"):
            command.add_argument("--max-lookups", type=int, required=True)
            command.add_argument(
                "--max-seconds",
                type=float,
                required=True,
                help="stop dispatch at this limit (one in-flight request may take up to 12s)",
            )
    args = parser.parse_args()
    directory = ignored_output(args.output_dir)
    with exclusive(directory):
        if args.command == "prepare":
            result = prepare(directory, args.input, args.private, args.ledger_query)
        elif args.command == "status":
            result = status(directory)
        elif args.command == "migrate-private-guard":
            manifest, _, queries = load(directory)
            if not manifest["private"]:
                raise ValueError("Only private collections have a privacy guard")
            private_candidates(directory, manifest, queries, migrate=True)
            result = status(directory, "private_guard_migrated")
        else:
            if version("ddgs") != "9.16.0":
                raise ValueError("Production collection requires ddgs==9.16.0")
            result = collect(directory, args.max_lookups, args.max_seconds)
    print(canonical(result), flush=True)


if __name__ == "__main__":
    main()
