"""Privately snapshot a readable plaintext vault and export evidence, never labels.

Uses SQLite's online backup API with a read-only source connection, including
committed WAL data. Does not open LedgerStore (which migrates), request Keychain
credentials, change encryption, or print transaction content. Encrypted vaults
require an explicitly provided plaintext backup; this tool never extracts keys.
All output is private. The full source snapshot retains sensitive source data.
Run from the repository root with ``python -m scripts.export_training_snapshot``.
"""

import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import sqlite3
import sys

from groundkeeper.policy import validate_input

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = (
    Path.home()
    / "Library/Containers/com.groundkeeper.macos/Data/Library/Application Support/GroundKeeper/vault.sqlite"
)


class SnapshotBlocked(Exception):
    """A safe, content-free reason why export cannot proceed."""


def bounded(text, limit=1600):
    return text.encode("utf-8")[:limit].decode("utf-8", errors="ignore")


def sanitize(text):
    """Remove explicit monetary values and common identifiers from model inputs.

    This is a conservative deterministic minimization pass, not a guarantee that
    arbitrary free text contains no personal information. Outputs stay private.
    """
    text = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "[email]", text)
    text = re.sub(r"(?i)\b(?:https?://|www\.)\S+", "[url]", text)
    text = re.sub(r"(?i)\b(?:card|account|acct|order|invoice|reference|confirmation)\s*(?:no\.?|number|#|ending)?\s*[:*x -]*\d{4,}\b", "[identifier]", text)
    text = re.sub(r"(?<!\w)(?:\+?1[-. ]?)?\(?\d{3}\)?[-. ]\d{3}[-. ]\d{4}(?!\w)", "[phone]", text)
    text = re.sub(r"\b\d{4}[-/]\d{1,2}[-/]\d{1,2}\b|\b\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\b", "[date]", text)
    text = re.sub(r"(?i)\b[A-Z]\d[A-Z][ -]?\d[A-Z]\d\b", "[postal-code]", text)
    text = re.sub(r"(?:\*{2,}|[xX]{2,})[ -]*\d{3,}", "[identifier]", text)
    text = re.sub(r"\b\d{8,}\b", "[identifier]", text)
    text = re.sub(r"(?i)(?:[$€£¥]\s*[+-]?\d[\d,]*(?:\.\d+)?|\b(?:CAD|USD|EUR|GBP)\s+[+-]?\d[\d,]*(?:\.\d+)?|\b\d[\d,]*\.\d{2}\b)", "[amount]", text)
    return text


def receipt_context(texts):
    """Mirror ReceiptContext.select's bounded line selection, then minimize."""
    full = "\n\n".join(text for text in texts if text.strip())
    if not full:
        return None
    excluded = re.compile(r"visa|mastercard|amex|card\s*(no|number)|a[ui]th\s*code|loyalty|member\s*(id|no)|\*{4,}|https?://|www\.", re.I)
    lines = []
    for line in full.splitlines():
        line = line.strip()
        if line and not excluded.search(line):
            line = re.sub(r"\b[0-9]{8,}\b", "[identifier]", line)
            if line != "[identifier]":
                lines.append(line)
    selected, truncated = "", False
    for line in lines:
        candidate = selected + "\n" + line if selected else line
        if len(candidate.encode()) > 1600:
            truncated = True
            if not selected:
                selected = bounded(line)
            break
        selected = candidate
    if not selected:
        return None
    minimized = sanitize(selected)
    truncated = truncated or len(minimized.encode()) > 1600
    return {"version": "receipt-context-v1", "text": bounded(minimized), "truncated": truncated,
            "evidence_sha256": hashlib.sha256(full.encode()).hexdigest()}


def wallet_hint(db, transaction_id):
    hints = set()
    for (raw,) in db.execute("""
        SELECT p.payload_json FROM transaction_event_links l
        JOIN raw_events e ON e.id=l.event_id JOIN sources s ON s.id=e.source_id
        JOIN raw_event_payloads p ON p.event_id=e.id
        WHERE l.transaction_id=? AND l.unlinked_at_ms IS NULL
          AND e.is_test=0 AND s.kind='apple_wallet'
        ORDER BY e.captured_at_ms,e.id
    """, (transaction_id,)):
        try:
            hint = json.loads(raw).get("wallet_category_raw")
        except (ValueError, AttributeError):
            continue
        if (isinstance(hint, str) and hint.strip() and len(hint.encode()) <= 128
                and not any(ord(char) < 32 or ord(char) == 127 for char in hint)):
            hints.add(hint)
    return next(iter(hints)) if len(hints) == 1 else None


def private_file(path):
    """Create exclusively with private permissions, including before first write."""
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8")


def write_json(path, value):
    with private_file(path) as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
    path.chmod(0o600)


def export_snapshot(source, destination):
    source, destination = Path(source).resolve(), Path(destination).resolve()
    private_root = (ROOT / ".private").resolve()
    if not destination.is_relative_to(private_root):
        raise SnapshotBlocked("Output must be inside the repository's ignored .private directory.")
    if destination.exists():
        raise SnapshotBlocked("Output directory already exists; choose a fresh private directory.")
    try:
        with source.open("rb") as stream:
            if stream.read(16) != b"SQLite format 3\0":
                raise SnapshotBlocked("Source is encrypted or is not SQLite. Provide an authorized plaintext backup; no keys were requested.")
    except PermissionError as error:
        raise SnapshotBlocked("macOS denied access to the vault. Grant Codex access or provide an authorized consistent backup in .private.") from error
    except FileNotFoundError as error:
        raise SnapshotBlocked("Source vault was not found.") from error
    private_root.mkdir(mode=0o700, exist_ok=True)
    directory = private_root
    for component in destination.relative_to(private_root).parts[:-1]:
        directory /= component
        directory.mkdir(mode=0o700, exist_ok=True)
    destination.mkdir(mode=0o700)
    destination.chmod(0o700)
    snapshot = destination / "source.snapshot.sqlite"
    try:
        with private_file(snapshot):
            pass
        with sqlite3.connect(source.as_uri() + "?mode=ro", uri=True) as live:
            live.execute("PRAGMA query_only=ON")
            with sqlite3.connect(snapshot) as copy:
                live.backup(copy)
        snapshot.chmod(0o400)
        db = sqlite3.connect(snapshot.as_uri() + "?mode=ro&immutable=1", uri=True)
        db.row_factory = sqlite3.Row
        with db:
            if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise SnapshotBlocked("Snapshot failed integrity validation.")
            if db.execute("PRAGMA foreign_key_check").fetchone() is not None:
                raise SnapshotBlocked("Snapshot failed foreign-key validation.")
            versions = [dict(row) for row in db.execute("SELECT version,name,checksum FROM schema_migrations ORDER BY version")]
            secret = os.urandom(32)
            key_path = destination / ".opaque-id-key"
            with os.fdopen(os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
                stream.write(secret)
            def opaque(kind, value):
                return kind + "_" + hmac.new(secret, (kind + "|" + value).encode(), hashlib.sha256).hexdigest()[:24]
            counts = Counter(active_transactions=0)
            inputs_path = destination / "classifier_inputs.jsonl"
            labels_path = destination / "existing_labels.untrusted.jsonl"
            mapping_path = destination / "private_source_id_map.jsonl"
            with private_file(inputs_path) as inputs, private_file(labels_path) as labels, private_file(mapping_path) as mapping:
                for row in db.execute("SELECT id,description,amount_minor,currency,notes,merchant_id,revision FROM transactions WHERE state='active' ORDER BY id"):
                    tx = row["id"]
                    record_id = opaque("transaction", tx)
                    description = sanitize(row["description"])
                    model_input = {"description": description, "direction": "debit" if row["amount_minor"] < 0 else "credit", "currency": row["currency"]}
                    notes = bounded(row["notes"].strip())
                    if notes:
                        model_input["transaction_notes"] = bounded(sanitize(notes))
                        counts["with_notes"] += 1
                    texts = [entry[0] for entry in db.execute("""
                        SELECT o.text FROM receipt_captures r JOIN receipt_ocr_runs o ON o.id=(
                          SELECT id FROM receipt_ocr_runs WHERE receipt_id=r.id ORDER BY created_at_ms DESC,rowid DESC LIMIT 1)
                        WHERE r.transaction_id=? AND r.removed_at_ms IS NULL ORDER BY r.captured_at_ms,r.id
                    """, (tx,))]
                    receipt = receipt_context(texts)
                    if receipt:
                        model_input["receipt_context"] = receipt
                        counts["with_receipt_context"] += 1
                    hint = wallet_hint(db, tx)
                    if hint:
                        model_input["wallet_category_raw"] = bounded(sanitize(hint), 128)
                        counts["with_wallet_hint"] += 1
                    validate_input(model_input)
                    normalized = " ".join(description.casefold().split())
                    merchant_key = row["merchant_id"] or re.sub(r"\d+", "#", normalized)
                    record = {"id": record_id, "input": model_input, "split_groups": {
                        "transaction": record_id, "description": opaque("description", normalized),
                        "merchant": opaque("merchant", merchant_key)}, "source_revision": row["revision"]}
                    inputs.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
                    mapping.write(json.dumps({"id": record_id, "source_transaction_id": tx}) + "\n")
                    old = [dict(entry) for entry in db.execute("""
                        SELECT p.position,a.type_code,c.code AS category_code,a.origin,a.needs_review,
                               a.confirmed_at_ms IS NOT NULL AS user_confirmed
                        FROM transaction_parts p LEFT JOIN category_assignments a ON a.id=p.current_assignment_id
                        LEFT JOIN categories c ON c.id=a.category_id WHERE p.transaction_id=? ORDER BY p.position
                    """, (tx,))]
                    labels.write(json.dumps({"id": record_id, "trusted": False, "parts": old}, sort_keys=True) + "\n")
                    counts["active_transactions"] += 1
            for path in (inputs_path, labels_path, mapping_path):
                path.chmod(0o600)
            manifest = {"format": "groundkeeper-private-evidence-v3", "created_at_utc": datetime.now(timezone.utc).isoformat(),
                "source": str(source), "snapshot_method": "SQLite online backup, read-only source, committed WAL included",
                "snapshot_sha256": hashlib.sha256(snapshot.read_bytes()).hexdigest(), "migrations": versions,
                "transaction_states": dict(db.execute("SELECT state,count(*) FROM transactions GROUP BY state")),
                "counts": dict(counts), "labels": "Untrusted comparison only; excluded from classifier inputs",
                "input_minimization": "No amount/account/location/date fields; common identifiers, email/phone/URL patterns, numeric dates, Canadian postal codes and explicit monetary values redacted. Arbitrary free text may retain personal information and remains private.",
                "split_guidance": "Keep transaction, normalized description, and heuristic merchant groups together; inspect grouping before final split.",
                "evidence_semantics": "Current ledger notes capped at 1600 UTF-8 bytes; newest OCR per nonremoved receipt with app line selection; nonconflicting Wallet hints from live linked non-test events."}
            write_json(destination / "manifest.private.json", manifest)
        db.close()
    except (sqlite3.Error, OSError, ValueError) as error:
        raise SnapshotBlocked("Database snapshot/export failed; no source writes were requested. Any partial output remains private.") from error
    return dict(counts)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--destination", type=Path, default=ROOT / ".private/qwen-evidence-v3/snapshot")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        counts = export_snapshot(args.source, args.destination)
    except SnapshotBlocked as error:
        print(f"Blocked: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"status": "exported", "counts": counts}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
