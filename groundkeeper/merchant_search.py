"""DuckDuckGo-only retrieval service. Receives public query terms, never a ledger."""

import json
import re
import time
import unicodedata
from urllib.parse import urlsplit

from .merchant_context import MAX_BYTES, VERSION, validate_context

HOST = "html.duckduckgo.com"
GAP_SECONDS = 10.5


def _normal(text):
    text = text.replace("’", "").replace("'", "")
    return re.sub(
        r"[^a-z0-9]+",
        " ",
        unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower(),
    ).strip()


def _bounded(text, size):
    return " ".join(str(text or "").split()).encode()[:size].decode("utf-8", "ignore")


def select_context(raw, merchant, locality):
    """Conservative name/locality matching; no inferred business descriptions."""
    name = set(_normal(merchant).split()) - {"the", "inc", "ltd", "llc", "corp"}
    city = set(_normal(locality).split()) - {"ontario", "canada", "on", "ca"}
    if not name or max(map(len, name)) < 3:
        return None
    selected, seen = [], set()
    for result in raw:
        if not isinstance(result, dict):
            continue
        title, body, url = (
            _bounded(result.get(k), n) for k, n in (("title", 120), ("body", 360), ("href", 320))
        )
        parsed = urlsplit(url)
        if (
            not title
            or not body
            or parsed.scheme not in ("https", "http")
            or not parsed.hostname
            or parsed.username
            or parsed.password
        ):
            continue
        # Never visit result URLs. Remove tracking/query/fragment data from evidence.
        url = parsed._replace(query="", fragment="").geturl()
        words = set(_normal(title + " " + body + " " + parsed.hostname).split())
        if not name <= words or (city and not city <= words) or url in seen:
            continue
        candidate = {"title": title, "body": body, "url": url}
        context = {"version": VERSION, "source": "duckduckgo", "results": selected + [candidate]}
        if len(json.dumps(context, ensure_ascii=False, separators=(",", ":")).encode()) > MAX_BYTES:
            continue
        try:
            validate_context(context)
        except ValueError:
            continue
        selected.append(candidate)
        seen.add(url)
        if len(selected) == 2:
            break
    return {"version": VERSION, "source": "duckduckgo", "results": selected} if selected else None


class MerchantSearch:
    def __init__(self):
        self.client = None
        self.next_search = 0.0
        self.blocked = False
        self.blocked_until = 0.0
        self.engine_class = None
        self.diagnostic = None

    def search(self, merchant, locality, cancelled=lambda: False, event=lambda _: None):
        from importlib.metadata import version

        if version("ddgs") != "9.16.0":
            raise RuntimeError("Unsupported search runtime")
        import ddgs.ddgs as implementation
        from ddgs import DDGS
        from ddgs.engines.duckduckgo import Duckduckgo
        from ddgs.http_client import HttpClient

        if self.blocked and time.monotonic() < self.blocked_until:
            return {"outcome": "blocked", "context": None}
        self.blocked = False
        if time.monotonic() < self.next_search:
            event({"stage": "search_cooldown"})
        while time.monotonic() < self.next_search:
            if cancelled():
                raise InterruptedError()
            time.sleep(max(0, min(0.1, self.next_search - time.monotonic())))
        if cancelled():
            raise InterruptedError()

        class SystemDNSDuckduckgo(Duckduckgo):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                import primp

                stock = self.http_client.client
                # macOS sandboxed helpers cannot read the resolver configuration
                # used by primp's default resolver. Use getaddrinfo through macOS,
                # retaining the stock chosen browser/OS profile and TLS validation.
                self.http_client.client = primp.Client(
                    timeout=12,
                    dns_resolver="system",
                    impersonate=stock.impersonate,
                    impersonate_os=stock.impersonate_os,
                    verify=True,
                    follow_redirects=False,
                    https_only=True,
                )

        if self.engine_class is None:
            self.engine_class = SystemDNSDuckduckgo
        implementation.ENGINES = {"text": {"duckduckgo": self.engine_class}}
        DDGS.threads = 1
        if self.client is None:
            self.client = DDGS(timeout=12)
        original = HttpClient.request
        self.diagnostic = None

        def guarded(client, method, url, *args, **kwargs):
            parsed = urlsplit(url)
            if (
                parsed.scheme != "https"
                or parsed.hostname != HOST
                or parsed.path != "/html/"
                or parsed.username
                or parsed.password
                or parsed.port not in (None, 443)
            ):
                raise RuntimeError("Disallowed search destination")
            if cancelled():
                raise InterruptedError()
            # A redirect is not needed for the verified endpoint. Never follow it.
            kwargs["follow_redirects"] = False
            try:
                response = original(client, method, url, *args, **kwargs)
            except Exception as error:
                # Only fixed diagnostic labels cross XPC, never dependency messages.
                text = str(error).lower()
                self.diagnostic = next(
                    (
                        code
                        for word, code in (
                            ("certificate", "tls_certificate"),
                            ("cert", "tls_certificate"),
                            ("dns", "dns"),
                            ("resolve", "dns"),
                            ("permission", "permission"),
                            ("timed out", "timeout"),
                            ("connect", "connection"),
                        )
                        if word in text
                    ),
                    "transport",
                )
                raise
            text = response.text.lower()
            if response.status_code in (403, 429) or any(
                marker in text
                for marker in (
                    "anomaly-modal",
                    "challenge-form",
                    "unfortunately, bots",
                    "select all squares",
                    "verify you are human",
                    "verify that you are human",
                    "prove you are human",
                    "schedule a captcha",
                )
            ):
                self.blocked = True
                self.blocked_until = time.monotonic() + 900
                raise RuntimeError("Search blocked")
            if response.status_code != 200 or len(response.content) > 2_000_000:
                self.diagnostic = (
                    "http_status" if response.status_code != 200 else "response_too_large"
                )
                raise RuntimeError("Search unavailable")
            return response

        HttpClient.request = guarded
        try:
            event({"stage": "searching_duckduckgo"})
            raw = self.client.text(
                " ".join(filter(None, (merchant, locality))),
                backend="duckduckgo",
                region="ca-en",
                max_results=5,
            )
            if cancelled():
                raise InterruptedError()
            context = select_context(raw, merchant, locality)
            return {"outcome": "matched" if context else "no_match", "context": context}
        except InterruptedError:
            raise
        except Exception as error:
            # The pinned DDGS adapter reports a successful empty page this way.
            empty = type(error).__name__ == "DDGSException" and str(error) == "No results found."
            return {
                "outcome": "blocked" if self.blocked else "no_match" if empty else "unavailable",
                "context": None,
                "diagnostic": self.diagnostic or "adapter",
            }
        finally:
            HttpClient.request = original
            self.next_search = time.monotonic() + GAP_SECONDS

    def handle(self, request, cancelled=lambda: False, event=lambda _: None):
        request_id = request.get("request_id") if isinstance(request, dict) else None
        try:
            if (
                not isinstance(request, dict)
                or request.get("protocol_version") != 1
                or not isinstance(request_id, str)
                or not 1 <= len(request_id) <= 128
            ):
                raise ValueError()
            if request.get("operation") == "search_handshake":
                from importlib.metadata import version

                result = {"version": VERSION, "ddgs_version": version("ddgs")}
            elif request.get("operation") == "merchant_search":
                merchant, locality = request["merchant"], request["locality"]
                if (
                    not all(isinstance(v, str) for v in (merchant, locality))
                    or not merchant.strip()
                    or len(merchant.encode()) > 120
                    or len(locality.encode()) > 80
                ):
                    raise ValueError()
                if any(ord(c) < 32 or ord(c) == 127 for c in merchant + locality) or re.search(
                    r"[@$€£]|https?://|\b\d+\b", merchant + " " + locality
                ):
                    raise ValueError()
                result = self.search(merchant, locality, cancelled, event)
            else:
                raise ValueError()
            return {
                "protocol_version": 1,
                "request_id": request_id,
                "status": "succeeded",
                "result": result,
            }
        except InterruptedError:
            code = "cancelled"
        except (ValueError, TypeError, KeyError):
            code = "invalid_request"
        except Exception:
            code = "search_unavailable"
        return {
            "protocol_version": 1,
            "request_id": request_id,
            "status": "failed",
            "error": {"code": code, "message": "Merchant search could not complete"},
        }


_search = None


def dispatch(encoded, package_root=None):
    import gk_native

    global _search
    if _search is None:
        _search = MerchantSearch()
    try:
        request = json.loads(encoded)
    except (ValueError, TypeError):
        request = None
    return json.dumps(
        _search.handle(request, gk_native.cancelled, lambda e: gk_native.event(json.dumps(e))),
        separators=(",", ":"),
        allow_nan=False,
    )
