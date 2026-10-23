"""Bounded, DuckDuckGo-only DDGS retrieval diagnostic using public names.

No model is loaded. This records evidence for manual inspection; it does not
infer categories or measure classification accuracy. Raw snippets stay local.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
from pathlib import Path
import platform
import subprocess
import sys
import time
from urllib.parse import urlsplit


PINNED_DDGS = "9.16.0"
ALLOWED_HOST = "html.duckduckgo.com"


def search_one(case: dict, client=None) -> dict:
    import ddgs.ddgs as implementation
    from ddgs import DDGS
    from ddgs.engines.duckduckgo import Duckduckgo
    from ddgs.http_client import HttpClient

    version = importlib.metadata.version("ddgs")
    if version != PINNED_DDGS:
        raise RuntimeError(f"Expected ddgs {PINNED_DDGS}, found {version}")
    # Prevent DDGS's automatic fallback from ever selecting a second engine.
    implementation.ENGINES = {"text": {"duckduckgo": Duckduckgo}}
    DDGS.threads = 1
    requests: list[dict] = []
    original_request = HttpClient.request
    challenge_seen = False

    def guarded_request(self, method, url, *args, **kwargs):
        nonlocal challenge_seen
        parsed = urlsplit(url)
        if parsed.scheme != "https" or parsed.hostname != ALLOWED_HOST:
            raise RuntimeError(f"Disallowed search host: {parsed.hostname}")
        # Never follow a redirect to an unrecorded destination or challenge.
        kwargs["follow_redirects"] = False
        started = time.monotonic()
        item = {"method": method, "url": url}
        requests.append(item)
        try:
            response = original_request(self, method, url, *args, **kwargs)
        except Exception as exc:
            item.update(elapsed_seconds=round(time.monotonic() - started, 3), error_type=type(exc).__name__)
            raise
        text = response.text
        challenge_seen = response.status_code in (403, 429) or any(
            marker in text.lower()
            for marker in ("anomaly-modal", "challenge-form", "unfortunately, bots", "select all squares")
        )
        item.update(
            elapsed_seconds=round(time.monotonic() - started, 3),
            status=response.status_code,
            bytes=len(response.content),
            body_sha256=hashlib.sha256(response.content).hexdigest(),
            challenge_detected=challenge_seen,
        )
        if challenge_seen:
            raise RuntimeError("DuckDuckGo challenge/rate limit; no retry or bypass")
        return response

    HttpClient.request = guarded_request
    started = time.monotonic()
    record = {
        **case,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "ddgs_version": version,
        "transport": "stock-post",
        "backend": "duckduckgo",
        "region": "ca-en",
        "max_results": 5,
    }
    try:
        results = (client or DDGS(timeout=12)).text(
            case["query"], backend="duckduckgo", region="ca-en", max_results=5
        )
        nonempty = [r for r in results if r.get("href") and (r.get("title") or r.get("body"))]
        # Preserve the raw adapter output: its no-results page can yield one
        # dictionary whose title, URL and body are all blank.
        record.update(status="results" if nonempty else "empty", results=results, nonempty_result_count=len(nonempty))
    except Exception as exc:
        record.update(
            status="blocked" if challenge_seen else "failed",
            error_type=type(exc).__name__,
            error=str(exc)[:800],
            results=[],
        )
    finally:
        HttpClient.request = original_request
    record.update(elapsed_seconds=round(time.monotonic() - started, 3), requests=requests)
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, default=Path("experiments/merchant-search/cases.json"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--ids", nargs="+")
    parser.add_argument("--gap-seconds", type=float, default=4)
    parser.add_argument("--shared-client", action="store_true", help="Reuse the DDGS HTTP client between queries")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--worker", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        print(json.dumps(search_one(json.loads(args.worker))), flush=True)
        return
    payload = json.loads(args.cases.read_text())
    cases = payload["cases"]
    ids = [case["id"] for case in cases]
    if len(ids) != len(set(ids)) or not cases:
        parser.error("Cases must have unique IDs and be nonempty")
    if any(not isinstance(c["query"], str) or not c["query"].strip() for c in cases):
        parser.error("Queries must be nonempty strings")
    if args.ids:
        if set(args.ids) - set(ids):
            parser.error("Unknown case ID")
        cases = [case for case in cases if case["id"] in args.ids]
    if args.validate_only:
        print(json.dumps({"valid": True, "case_count": len(cases), "ids": [c["id"] for c in cases]}))
        return
    if not args.output or args.gap_seconds < 3:
        parser.error("An output path and at least a three-second gap are required")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    failures = 0
    client = None
    if args.shared_client:
        from ddgs import DDGS
        client = DDGS(timeout=12)
    with args.output.open("x") as output:
        output.write(json.dumps({
            "record_type": "manifest",
            "cases_sha256": hashlib.sha256(args.cases.read_bytes()).hexdigest(),
            "python": platform.python_version(),
            "packages": {name: importlib.metadata.version(name) for name in ("ddgs", "primp", "lxml", "click")},
            "transport": "stock-post",
            "shared_client": args.shared_client,
            "allowed_search_hosts": [ALLOWED_HOST],
            "model_calls": 0,
        }) + "\n")
        output.flush()
        for index, case in enumerate(cases):
            if index:
                time.sleep(args.gap_seconds)
            command = [sys.executable, __file__, "--worker", json.dumps(case)]
            try:
                if client is not None:
                    record = search_one(case, client)
                else:
                    process = subprocess.run(command, capture_output=True, text=True, timeout=30, check=False)
                    if process.returncode:
                        record = {**case, "status": "worker_error", "stderr": process.stderr[-1200:], "results": []}
                    else:
                        record = json.loads(process.stdout)
            except subprocess.TimeoutExpired:
                record = {**case, "status": "timeout", "results": []}
            output.write(json.dumps(record, ensure_ascii=False) + "\n")
            output.flush()
            print(json.dumps({"id": case["id"], "status": record["status"], "raw_result_count": len(record["results"]), "nonempty_result_count": record.get("nonempty_result_count", 0), "elapsed_seconds": record.get("elapsed_seconds")}), flush=True)
            failures = 0 if record["status"] == "results" else failures + 1
            if record["status"] == "blocked" or failures >= 3:
                print("Stopping after a challenge or three consecutive unsuccessful queries.", flush=True)
                break


if __name__ == "__main__":
    main()
