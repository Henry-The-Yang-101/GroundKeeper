"""Apple Shortcuts adapter with optional receipt and Wallet category evidence."""

import json
import subprocess
import tempfile
import time
from pathlib import Path

from .policy import parse_answer, validate_input


class ShortcutExecutionError(RuntimeError):
    def __init__(self, message, detail):
        super().__init__(message)
        self.detail = detail


def run_shortcut(inputs, shortcut="GK Categorize Cloud", timeout=60, cancelled=None):
    """Return the semantic suggestion and audit detail; never send gold labels."""
    validate_input(inputs)
    start = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="gk-shortcut-") as directory:
        request = Path(directory) / "request.txt"
        response = Path(directory) / "response.txt"
        request.write_text(json.dumps(inputs, ensure_ascii=False), encoding="utf-8")
        command = [
            "/usr/bin/shortcuts",
            "run",
            shortcut,
            "--input-path",
            str(request),
            "--output-path",
            str(response),
        ]
        try:
            if cancelled is None:
                process = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
            else:
                # The app path must observe native XPC cancellation and never retain
                # a child process after a queue handoff. Keep stderr temporary and
                # expose only safe error codes through the worker boundary.
                with (
                    tempfile.TemporaryFile() as errors,
                    subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=errors) as child,
                ):
                    try:
                        while child.poll() is None:
                            if cancelled():
                                raise ShortcutExecutionError(
                                    "Shortcut cancelled", {"status": "cancelled"}
                                )
                            if time.monotonic() - start >= timeout:
                                raise subprocess.TimeoutExpired(command, timeout)
                            time.sleep(0.05)
                        errors.seek(0)
                        stderr = errors.read(65536).decode("utf-8", errors="replace")
                        process = subprocess.CompletedProcess(command, child.returncode, "", stderr)
                    finally:
                        if child.poll() is None:
                            child.kill()
                        child.wait()

        except subprocess.TimeoutExpired as error:
            detail = {
                "status": "timeout",
                "latency_seconds": time.monotonic() - start,
                "error": f"Shortcut exceeded {timeout} seconds",
                "valid_schema": False,
            }
            raise ShortcutExecutionError(detail["error"], detail) from error
        if response.exists() and response.stat().st_size > 65536:
            raise ShortcutExecutionError("Shortcut output too large", {"status": "invalid_output"})
        raw = response.read_text(encoding="utf-8") if response.exists() else ""
        detail = {
            "raw": raw,
            "returncode": process.returncode,
            "stdout": process.stdout,
            "stderr": process.stderr,
            "latency_seconds": time.monotonic() - start,
            "valid_schema": False,
        }
        if process.returncode != 0 or not response.exists():
            detail["status"] = (
                "rate_limited"
                if any(
                    term in process.stderr.lower()
                    for term in ("usage limit", "too many incoming", "rate limit")
                )
                else "execution_error"
            )
            message = process.stderr.strip() or "Shortcut did not produce an output file"
            raise ShortcutExecutionError(message, detail)
        try:
            answer = parse_answer(raw)
        except (ValueError, TypeError) as error:
            detail.update(status="invalid_output", error=str(error))
            raise ShortcutExecutionError(
                "Shortcut output violates the decision schema", detail
            ) from error
        detail.update(
            status="ok", valid_schema=True, removed_json_fence=raw.strip().startswith("```")
        )
        return answer, detail


class AppleShortcutCategorizer:
    """Application wrapper: semantic predictions remain suggestions for review."""

    def __init__(self, shortcut="GK Categorize Cloud", timeout=60):
        self.shortcut, self.timeout = shortcut, timeout

    def suggest(self, inputs, cancelled=None):
        answer, _ = run_shortcut(inputs, self.shortcut, self.timeout, cancelled=cancelled)
        return {**answer, "review": True}
