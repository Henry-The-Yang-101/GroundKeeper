"""Bounded, isolated-engine DDGS retrieval diagnostic using public names.

No model is loaded. This records evidence for manual inspection; it does not
infer categories or measure classification accuracy. Raw snippets stay local.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import platform
import re
import subprocess
import sys
import time
from urllib.parse import urljoin, urlsplit


PINNED_DDGS = "9.16.0"
ENGINE_HOSTS = {
    "duckduckgo": ("html.duckduckgo.com",),
    "bing": ("www.bing.com",),
    "brave": ("search.brave.com",),
    "google": ("www.google.com",),
}


def search_one(case: dict, client=None, engine: str = "duckduckgo", response_dir: Path | None = None, adapter_variant: str = "stock") -> dict:
    import ddgs.ddgs as implementation
    from ddgs import DDGS
    from ddgs.engines.duckduckgo import Duckduckgo
    from ddgs.engines.bing import Bing
    from ddgs.engines.brave import Brave
    from ddgs.engines.google import Google
    from ddgs.http_client import HttpClient

    version = importlib.metadata.version("ddgs")
    if version != PINNED_DDGS:
        raise RuntimeError(f"Expected ddgs {PINNED_DDGS}, found {version}")
    engine_class = {"duckduckgo": Duckduckgo, "bing": Bing, "brave": Brave, "google": Google}[engine]
    upstream_disabled = engine_class.disabled
    if adapter_variant == "bing-selectors":
        if engine != "bing":
            raise ValueError("bing-selectors is only valid for Bing")
        engine_class = type("BingSelectorDiagnostic", (Bing,), {
            "elements_xpath": {
                "title": ".//h2//text()",
                "href": "(.//a[h2]/@href | .//h2/a/@href)[1]",
                "body": ".//p//text()",
            },
        })
    elif adapter_variant == "google-standard-route":
        if engine != "google":
            raise ValueError("google-standard-route is only valid for Google")
        engine_class = type("GoogleRouteDiagnostic", (Google,), {"search_url": "https://www.google.com/search"})
    # Register exactly one adapter. This also makes a deliberately selected,
    # upstream-disabled adapter testable without falling back to another engine.
    implementation.ENGINES = {"text": {engine: engine_class}}
    DDGS.threads = 1
    requests: list[dict] = []
    original_request = HttpClient.request
    challenge_seen = False
    block_reason = None

    def guarded_request(self, method, url, *args, **kwargs):
        nonlocal challenge_seen, block_reason
        parsed = urlsplit(url)
        if parsed.scheme != "https" or parsed.hostname not in ENGINE_HOSTS[engine]:
            raise RuntimeError(f"Disallowed search host: {parsed.hostname}")
        # Follow ordinary same-provider redirects explicitly so each destination
        # is recorded and checked. Challenge destinations are never followed.
        kwargs["follow_redirects"] = False
        started = time.monotonic()
        item = {"method": method, "url": url, "query_parameters": kwargs.get("params", kwargs.get("data")), "started_monotonic": started}
        requests.append(item)
        try:
            response = original_request(self, method, url, *args, **kwargs)
        except Exception as exc:
            ended = time.monotonic()
            item.update(elapsed_seconds=round(ended - started, 3), ended_monotonic=ended, error_type=type(exc).__name__)
            raise
        ended = time.monotonic()
        text = response.text
        marker_seen = any(
            marker in text.lower()
            for marker in (
                "anomaly-modal", "challenge-form", "unfortunately, bots", "select all squares",
                "our systems have detected unusual traffic", "b_captcha", "b_cpt",
                "verify you are human", "verify that you are human", "prove you are human",
                "schedule a captcha",
            )
        )
        headers = getattr(response._resp, "headers", {})
        location = headers.get("location", "") if headers else ""
        redirect_to_challenge = any(marker in location.lower() for marker in ("/sorry/", "/captcha", "/challenge"))
        challenge_seen = marker_seen or redirect_to_challenge or response.status_code in (403, 429)
        block_reason = "bot_challenge" if marker_seen or redirect_to_challenge else (
            "http_429" if response.status_code == 429 else "http_403" if response.status_code == 403 else None
        )
        title_match = re.search(r"<title[^>]*>(.*?)</title>", text, flags=re.IGNORECASE | re.DOTALL)
        item.update(
            elapsed_seconds=round(ended - started, 3),
            ended_monotonic=ended,
            status=response.status_code,
            bytes=len(response.content),
            body_sha256=hashlib.sha256(response.content).hexdigest(),
            challenge_detected=challenge_seen,
            block_reason=block_reason,
            page_title=title_match.group(1).strip()[:200] if title_match else None,
            redirect_location=location or None,
        )
        if response_dir:
            response_dir.mkdir(parents=True, exist_ok=True)
            (response_dir / f"{case['id']}-{len(requests)}.html").write_text(text)
        if challenge_seen:
            raise RuntimeError(f"{engine} blocked ({block_reason}); no retry or bypass")
        if response.status_code in (301, 302, 303, 307, 308) and location:
            if len(requests) >= 4:
                raise RuntimeError("Redirect limit reached")
            redirected = {key: value for key, value in kwargs.items() if key != "params"}
            redirect_method = method
            if response.status_code == 303 or (method == "POST" and response.status_code in (301, 302)):
                redirect_method = "GET"
                redirected = {key: value for key, value in redirected.items() if key not in ("data", "content", "json")}
            return guarded_request(self, redirect_method, urljoin(url, location), *args, **redirected)
        return response

    HttpClient.request = guarded_request
    started = time.monotonic()
    record = {
        **case,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "ddgs_version": version,
        "transport": "stock-adapter",
        "backend": engine,
        "upstream_adapter_disabled": upstream_disabled,
        "adapter_variant": adapter_variant,
        "region": "ca-en",
        "max_results": 5,
    }
    try:
        results = (client or DDGS(timeout=12)).text(
            case["query"], backend=engine, region="ca-en", max_results=5
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
    record.update(elapsed_seconds=round(time.monotonic() - started, 3), requests=requests, block_reason=block_reason)
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, default=Path("experiments/merchant-search/cases.json"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--ids", nargs="+")
    parser.add_argument("--engine", choices=tuple(ENGINE_HOSTS), default="duckduckgo")
    parser.add_argument("--adapter-variant", choices=("stock", "bing-selectors", "google-standard-route"), default="stock")
    parser.add_argument("--response-dir", type=Path, help="Optional ignored local directory for diagnostic HTML")
    parser.add_argument("--gap-seconds", type=float, default=4)
    parser.add_argument("--shared-client", action="store_true", help="Reuse the DDGS HTTP client between queries")
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--worker", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.adapter_variant == "bing-selectors" and args.engine != "bing":
        parser.error("bing-selectors requires --engine bing")
    if args.adapter_variant == "google-standard-route" and args.engine != "google":
        parser.error("google-standard-route requires --engine google")
    if not math.isfinite(args.gap_seconds) or args.gap_seconds < 0.5:
        parser.error("The research pause must be finite and at least 0.5 seconds")
    if args.worker:
        print(json.dumps(search_one(json.loads(args.worker), engine=args.engine, response_dir=args.response_dir, adapter_variant=args.adapter_variant)), flush=True)
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
    if not args.output:
        parser.error("An output path is required")
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
            "transport": "stock-adapter",
            "backend": args.engine,
            "adapter_variant": args.adapter_variant,
            "shared_client": args.shared_client,
            "allowed_search_hosts": ENGINE_HOSTS[args.engine],
            "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "gap_seconds": args.gap_seconds,
            "model_calls": 0,
        }) + "\n")
        output.flush()
        for index, case in enumerate(cases):
            if index:
                time.sleep(args.gap_seconds)
            command = [sys.executable, __file__, "--worker", json.dumps(case), "--engine", args.engine, "--adapter-variant", args.adapter_variant]
            if args.response_dir:
                command.extend(("--response-dir", str(args.response_dir)))
            try:
                if client is not None:
                    record = search_one(case, client, args.engine, args.response_dir, args.adapter_variant)
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
