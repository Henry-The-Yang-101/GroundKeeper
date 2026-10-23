import copy
import json
import subprocess
import sys
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest

from groundkeeper.merchant_context import INSTRUCTIONS, validate_context
from groundkeeper.merchant_search import HOST, MerchantSearch, select_context
from groundkeeper.policy import messages, validate_input
from groundkeeper.policy_v2 import messages_v2
from groundkeeper.receipts import context_from_text, laya_receipt_state
from groundkeeper.laya_runtime import LocalLayaCategorizer
from groundkeeper.apple_shortcuts import run_shortcut

BASE = {"description": "Fictional Cafe", "direction": "debit", "currency": "CAD"}
RAW = [{"title": "Fictional Cafe Waterloo", "body": "Fictional Cafe in Waterloo is a neighbourhood cafe.", "href": "https://example.org/cafe?tracking=1"}]


def test_selection_checks_identity_locality_and_bounds():
    assert select_context(RAW, "Different Cafe", "Waterloo") is None
    assert select_context(RAW, "Fictional Cafe", "Toronto") is None
    assert select_context([{"title": "", "href": "", "body": ""}], "Fictional Cafe", "") is None
    context = select_context(RAW * 10, "Fictional Cafe", "Waterloo Ontario")
    assert len(context["results"]) == 1
    assert context["results"][0]["url"] == "https://example.org/cafe"
    assert validate_context(context) is context
    assert select_context([{**RAW[0], "href": "file:///private/local"}], "Fictional Cafe", "") is None


@pytest.mark.parametrize("field,value", [("source", "google"), ("version", "v0"), ("results", []), ("results", RAW)])
def test_context_schema_rejects_untrusted_shapes(field, value):
    context = select_context(RAW, "Fictional Cafe", "Waterloo")
    context[field] = value
    with pytest.raises(ValueError):
        validate_context(context)


@pytest.mark.parametrize("receipt", [False, True])
def test_all_providers_receive_optional_context_without_changing_original(receipt, monkeypatch):
    context = select_context(RAW, "Fictional Cafe", "Waterloo")
    inputs = {**BASE, "merchant_context": context, "wallet_category_raw": "Food & Drink"}
    if receipt:
        inputs["receipt_context"] = context_from_text("MILK\nBREAD")
    original = copy.deepcopy(inputs)
    validate_input(inputs)
    for builder in (messages, messages_v2):
        prompt = builder(inputs)
        assert INSTRUCTIONS in prompt[0]["content"]
        assert json.loads(prompt[1]["content"]) == inputs
    assert laya_receipt_state(inputs)["merchant_context"] == context
    observed = {}
    def predict(state, questions, **kwargs):
        observed.update(state=state, questions=questions)
        return {"answers": {}}
    model = LocalLayaCategorizer.__new__(LocalLayaCategorizer)
    model.agent = SimpleNamespace(predict=predict)
    model.predict(inputs)
    assert observed["state"]["merchant_context"] == context
    assert all(INSTRUCTIONS in q["instructions"] for q in observed["questions"].values())
    def execute(command, **kwargs):
        assert json.loads(Path(command[command.index("--input-path") + 1]).read_text()) == inputs
        Path(command[command.index("--output-path") + 1]).write_text('{"type":"expense","category":"dining","review":true}')
        return subprocess.CompletedProcess(command, 0, "", "")
    monkeypatch.setattr(subprocess, "run", execute)
    assert run_shortcut(inputs)[0]["review"]
    assert inputs == original


@pytest.fixture
def transport(monkeypatch):
    import importlib.metadata
    monkeypatch.setattr(importlib.metadata, "version", lambda _: "9.16.0")
    state = SimpleNamespace(status=200, html="<html>results</html>", calls=[], raw=RAW, clients=0, url=f"https://{HOST}/html/")
    class HTTP:
        def request(self, method, url, *args, **kwargs):
            state.calls.append((url, kwargs))
            return SimpleNamespace(status_code=state.status, text=state.html, content=state.html.encode())
    class DDGS:
        def __init__(self, **kwargs):
            state.clients += 1
        def text(self, query, **kwargs):
            assert kwargs == {"backend": "duckduckgo", "region": "ca-en", "max_results": 5}
            HTTP().request("POST", state.url)
            return state.raw
    modules = {name: ModuleType(name) for name in ("ddgs", "ddgs.ddgs", "ddgs.engines", "ddgs.engines.duckduckgo", "ddgs.http_client")}
    modules["ddgs"].DDGS = DDGS
    modules["ddgs.engines.duckduckgo"].Duckduckgo = object
    modules["ddgs.http_client"].HttpClient = HTTP
    modules["ddgs"].ddgs = modules["ddgs.ddgs"]
    for name, module in modules.items():
        monkeypatch.setitem(sys.modules, name, module)
    return state


def test_reuses_client_and_stops_on_challenge_without_fallback(transport):
    search = MerchantSearch()
    assert search.search("Fictional Cafe", "Waterloo")["outcome"] == "matched"
    assert search.next_search > 0
    assert transport.calls[0][1]["follow_redirects"] is False
    search.next_search = 0
    transport.status = 202; transport.html = "<div class='anomaly-modal'>challenge</div>"
    assert search.search("Fictional Cafe", "Waterloo")["outcome"] == "blocked"
    assert search.search("Fictional Cafe", "Waterloo")["outcome"] == "blocked"
    assert transport.clients == 1 and len(transport.calls) == 2
    assert list(sys.modules["ddgs.ddgs"].ENGINES["text"]) == ["duckduckgo"]


def test_network_guard_and_cancellation(transport):
    search = MerchantSearch()
    transport.url = "https://google.com/search"
    assert search.search("Fictional Cafe", "Waterloo")["outcome"] == "unavailable"
    assert transport.calls == []
    with pytest.raises(InterruptedError):
        search.search("Fictional Cafe", "Waterloo", cancelled=lambda: True)


def test_service_rejects_private_or_oversized_queries_before_network():
    search = MerchantSearch()
    for merchant in ("payer@example.com", "acct 12345678", "x" * 121, "Line\nBreak", "$50"):
        result = search.handle({"protocol_version": 1, "request_id": "test", "operation": "merchant_search", "merchant": merchant, "locality": "Waterloo"})
        assert result["status"] == "failed" and result["error"]["code"] == "invalid_request"
