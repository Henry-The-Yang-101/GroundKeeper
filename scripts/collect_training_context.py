"""Freeze and resume real production DuckDuckGo evidence for training inputs.

No labels or classifier predictions are produced. ``prepare`` runs the actual
Swift MerchantQueryPilot (description fallback, empty locality), or the distinct
MerchantTrainingQueryPilot with --ledger-query for frozen merchant/locality; only its public
merchant/locality projection can reach MerchantSearch.handle. Source input is
never sent to a search engine. Results are immutable per-row files; records.jsonl
and summary.json are replaceable exports. Use an ignored .private directory for
private inputs. Collection is deliberately serial and bounded on every run.
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
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


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
            cwd=ROOT, capture_output=True, text=True, check=True, timeout=300,
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
        if (canonical(existing) != canonical(rows) or manifest["private"] != private
                or manifest.get("ledger_query", False) != ledger_query):
            raise ValueError("Frozen inputs changed; use a new collection directory")
        return status(directory)
    if list(directory.glob("*.json*")) or (directory / "records").exists():
        raise ValueError("Incomplete preparation: use a new empty collection directory")
    (ROOT / ".local").mkdir(exist_ok=True)
    projected = project(rows, ledger_query=ledger_query)
    # Preserve source/split/family metadata too: it is part of the frozen source,
    # but never part of the subprocess or network projection.
    inputs = "".join(canonical(row) + "\n" for row in rows)
    queries = "".join(canonical({**row, "input_sha256": input_hash(value["input"])}) + "\n"
                      for value, row in zip(rows, projected))
    # Manifest is committed last. A partially prepared directory is never resumed.
    atomic_text(directory / "input.jsonl", inputs, immutable=True)
    atomic_text(directory / "queries.jsonl", queries, immutable=True)
    (directory / "records").mkdir()
    manifest = {
        "schema_version": 1, "created_at": timestamp(), "private": private,
        "row_count": len(rows), "input_sha256": sha256(inputs.encode()),
        "queries_sha256": sha256(queries.encode()),
        "source_sha256": source_hashes(LEDGER_SOURCES if ledger_query else SOURCES),
        "ledger_query": ledger_query,
        "query_builder": "GroundKeeperCore.MerchantSearchQuery.make",
        "query_projection": (
            "MerchantTrainingQueryPilot: frozen search_merchant/search_locality, exact description fallback"
            if ledger_query else "MerchantQueryPilot: description fallback, merchant=nil, locality=empty"
        ),
        "retrieval": "groundkeeper.merchant_search.MerchantSearch.handle",
        "engine": "duckduckgo", "region": "ca-en", "max_results": 5,
        "max_context_results": 2, "max_context_bytes": 1500,
        "gap_after_completion_seconds": GAP_SECONDS,
        "cache_ttl_ms": TTL_MS, "cache_capacity": 1000,
        "failure_delay_ms": DELAY_MS, "inflight_reservation_ms": 45_000,
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
    return sha256(("merchant-search-v1|" + query["merchant"].lower() + "|" +
                   query["locality"].lower()).encode())


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
    if (not isinstance(state, dict) or set(state) != {"not_before_ms", "cache"}
            or type(state["not_before_ms"]) is not int or state["not_before_ms"] < 0
            or not isinstance(state["cache"], dict)):
        raise ValueError("Invalid persisted collection state")
    for key, item in state["cache"].items():
        if (not isinstance(key, str) or len(key) != 64 or not isinstance(item, dict)
                or set(item) != {"evidence", "fetched_at_ms", "source_id"}
                or type(item["fetched_at_ms"]) is not int or item["fetched_at_ms"] < 0
                or not isinstance(item["source_id"], str)):
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


def status(directory, stop_reason=None):
    manifest, _, queries = load(directory)
    done = completed(directory, queries)
    state = load_state(directory)
    prune_cache(state, now_ms())
    pending = [row for row in queries if row["id"] not in done]
    unique = {cache_key(row["query"]) for row in pending if row["query"] is not None}
    misses = unique - set(state["cache"])
    result = {
        "rows": manifest["row_count"], "completed": len(done), "pending": len(pending),
        "outcomes": dict(Counter(row["outcome"] for row in done.values())),
        "cache_rows": sum(row["cached"] for row in done.values()),
        "pending_unique_safe_queries": len(unique), "estimated_new_lookups": len(misses),
        "minimum_spacing_seconds": max(0, len(misses) - 1) * GAP_SECONDS,
        "not_before_ms": state["not_before_ms"], "stop_reason": stop_reason,
    }
    # Export in frozen source order, irrespective of crashes or collection batch size.
    atomic_text(directory / "records.jsonl", "".join(canonical(done[row["id"]]) + "\n"
                for row in queries if row["id"] in done))
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
            query = row["query"]
            key = cache_key(query) if query is not None else None
            cached = query is not None and key in state["cache"]
            elapsed = 0.0
            fetched_at = current
            cache_source = None
            if query is None:
                evidence = {"outcome": "unsafe_query", "context": None}
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
                response = search.handle({
                    "protocol_version": 1, "request_id": "training-context",
                    "operation": "merchant_search", **query,
                }, cancelled=lambda: clock.monotonic() - started >= max_seconds)
                elapsed = clock.monotonic() - before
                attempts += 1
                if response.get("status") == "succeeded":
                    evidence = response["result"]
                elif response.get("error", {}).get("code") == "cancelled":
                    reason = "runtime_limit"
                    break
                else:
                    evidence = {"outcome": "unavailable", "context": None,
                                "diagnostic": response.get("error", {}).get("code", "search_unavailable")}
                validate_evidence(evidence)
                fetched_at = int(clock.time() * 1000)
                state["not_before_ms"] = fetched_at + DELAY_MS.get(evidence["outcome"], 10_500)
                if evidence["outcome"] in TTL_MS:
                    state["cache"][key] = {"evidence": evidence, "fetched_at_ms": fetched_at,
                                           "source_id": row["id"]}
                    prune_cache(state, fetched_at)
                write_json(directory / "state.json", state)
            validate_evidence(evidence)
            record = {
                **row, "query_status": "safe" if query is not None else "unsafe_query",
                "merchant_context": evidence.get("context"), "outcome": evidence["outcome"],
                "merchant_context_status": evidence["outcome"], "cached": cached,
                "retrieval_provenance": {
                    "engine": "duckduckgo", "region": "ca-en", "max_results": 5,
                    "query_builder": manifest["query_builder"],
                    "retrieval": manifest["retrieval"], "source_sha256": manifest["source_sha256"],
                    "fetched_at_ms": fetched_at, "recorded_at": timestamp(),
                    "cache_source_id": cache_source,
                    "lookup_wall_seconds_including_queue_wait": elapsed,
                    "network_attempted": query is not None and not cached and evidence["outcome"] != "backoff",
                    "diagnostic": evidence.get("diagnostic"),
                },
            }
            write_json(record_path(directory, row), record, immutable=True)
            done[row["id"]] = record
            print(canonical({"completed": len(done), "total": len(queries),
                             "lookups_this_run": attempts, "outcome": evidence["outcome"]}), flush=True)
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
    prepare_parser = subparsers.add_parser("prepare", help="freeze inputs and actual Swift query projections; no network")
    prepare_parser.add_argument("--input", type=Path, required=True)
    prepare_parser.add_argument("--private", action="store_true")
    prepare_parser.add_argument("--ledger-query", action="store_true",
                                help="use frozen search_merchant/search_locality with exact description fallback")
    for command in (prepare_parser, subparsers.add_parser("status"), subparsers.add_parser("collect")):
        command.add_argument("--output-dir", type=Path, required=True)
        if command.prog.endswith("collect"):
            command.add_argument("--max-lookups", type=int, required=True)
            command.add_argument("--max-seconds", type=float, required=True,
                                 help="stop dispatch at this limit (one in-flight request may take up to 12s)")
    args = parser.parse_args()
    directory = ignored_output(args.output_dir)
    with exclusive(directory):
        if args.command == "prepare":
            result = prepare(directory, args.input, args.private, args.ledger_query)
        elif args.command == "status":
            result = status(directory)
        else:
            if version("ddgs") != "9.16.0":
                raise ValueError("Production collection requires ddgs==9.16.0")
            result = collect(directory, args.max_lookups, args.max_seconds)
    print(canonical(result), flush=True)


if __name__ == "__main__":
    main()
