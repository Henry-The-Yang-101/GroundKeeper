"""Private export checks with app migrations and exclusively fictional records."""

import hashlib
import json
import sqlite3
import stat

import pytest

from groundkeeper.policy import validate_input
from scripts.database_schema import apply_migrations
from scripts import export_training_snapshot as snapshot
from test_database_schema import event, link, put, transaction


@pytest.fixture
def vault(tmp_path, monkeypatch):
    monkeypatch.setattr(snapshot, "ROOT", tmp_path)
    source = tmp_path / "fictional.sqlite"
    db = sqlite3.connect(source)
    apply_migrations(db)
    put(db, "sources", id="wallet", kind="apple_wallet", name="Fictional wallet", created_at_ms=0)
    put(db, "sources", id="bank", kind="bank_notification", name="Fictional bank", created_at_ms=0)
    put(db, "accounts", id="card", name="Fictional account", kind="credit_card", currency="CAD", created_at_ms=0)
    db.commit()
    yield db, source, tmp_path / ".private/qwen-evidence-v3/snapshot"
    db.close()


def jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def add_hint(db, key, value, *, source="wallet", unlinked=False):
    event(db, key, source)
    put(db, "raw_event_payloads", event_id=key, payload_json=json.dumps({"wallet_category_raw": value}))
    link(db, key + "link", key, "debit")
    if unlinked:
        db.execute("UPDATE transaction_event_links SET unlinked_at_ms=1 WHERE id=?", (key + "link",))


def add_receipt(db, key, *, removed=False):
    put(db, "receipt_captures", id=key, source_event_id=key, payload_sha256="fictional",
        payload_json="{}", captured_at_ms=1, parent_source_id="manual", parent_event_id="debit",
        transaction_id="debit", removed_at_ms=1 if removed else None)


def add_ocr(db, key, receipt, text, created=1):
    put(db, "receipt_ocr_runs", id=key, receipt_id=receipt, producer="user_text", text=text,
        text_sha256=hashlib.sha256(text.encode()).hexdigest(), created_at_ms=created)


def test_consistent_wal_snapshot_uses_all_active_rows_and_keeps_labels_separate(vault):
    db, source, destination = vault
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA wal_autocheckpoint=0")
    transaction(db, "debit", description="Fictional Cafe card ending 1234", notes="Dinner CAD 25.00")
    transaction(db, "credit", amount=1000, kind="refund", description="Fictional Cafe")
    transaction(db, "deleted")
    db.execute("UPDATE transactions SET state='deleted' WHERE id='deleted'")
    db.commit()
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    counts = snapshot.export_snapshot(source, destination)
    assert counts == {"active_transactions": 2, "with_notes": 1}
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before
    assert db.execute("SELECT count(*) FROM transactions").fetchone() == (3,)
    rows = jsonl(destination / "classifier_inputs.jsonl")
    assert [row["input"]["direction"] for row in rows] == ["credit", "debit"]
    assert all(validate_input(row["input"]) for row in rows)
    assert "1234" not in json.dumps(rows) and "25.00" not in json.dumps(rows)
    assert "category" not in json.dumps(rows) and "amount_minor" not in json.dumps(rows)
    labels = jsonl(destination / "existing_labels.untrusted.jsonl")
    assert all(row["trusted"] is False for row in labels)
    assert labels[0]["parts"][0]["type_code"] == "refund"
    mapping = jsonl(destination / "private_source_id_map.jsonl")
    assert {row["source_transaction_id"] for row in mapping} == {"debit", "credit"}
    assert all(row["id"].startswith("transaction_") for row in rows)
    manifest = json.loads((destination / "manifest.private.json").read_text())
    assert manifest["counts"]["active_transactions"] == 2
    assert manifest["transaction_states"] == {"active": 2, "deleted": 1}
    assert len(manifest["migrations"]) == 12
    assert manifest["snapshot_sha256"] == hashlib.sha256((destination / "source.snapshot.sqlite").read_bytes()).hexdigest()
    for path in destination.rglob("*"):
        assert stat.S_IMODE(path.stat().st_mode) == (0o400 if path.suffix == ".sqlite" else 0o600)
    assert stat.S_IMODE(destination.stat().st_mode) == 0o700
    assert stat.S_IMODE(destination.parent.stat().st_mode) == 0o700
    with sqlite3.connect((destination / "source.snapshot.sqlite").as_uri() + "?mode=ro&immutable=1", uri=True) as copied:
        assert copied.execute("SELECT count(*) FROM transactions").fetchone() == (3,)


def test_receipts_use_newest_ocr_tie_breaker_and_exclude_removed_receipts(vault):
    db, source, destination = vault
    transaction(db, "debit")
    add_receipt(db, "receipt")
    add_ocr(db, "ocr-old", "receipt", "OBSOLETE APPLES", 0)
    add_ocr(db, "ocr-tie-first", "receipt", "OBSOLETE BREAD")
    latest = "MILK 3.99\nVISA 1234\nwww.example.test\n123456789012\nEmail fake@example.test"
    add_ocr(db, "ocr-tie-latest", "receipt", latest)
    add_receipt(db, "removed", removed=True)
    add_ocr(db, "ocr-removed", "removed", "REMOVED EGGS")
    db.commit()
    assert snapshot.export_snapshot(source, destination)["with_receipt_context"] == 1
    receipt = jsonl(destination / "classifier_inputs.jsonl")[0]["input"]["receipt_context"]
    assert receipt["text"] == "MILK [amount]\nEmail [email]"
    assert receipt["evidence_sha256"] == hashlib.sha256(latest.encode()).hexdigest()


@pytest.mark.parametrize("values,expected", [
    (["Food & Drink", "Food & Drink"], "Food & Drink"),
    (["Food & Drink", "Shopping"], None),
    ([None, [], "", "  ", "bad\nhint", "界" * 43, "Food & Drink"], "Food & Drink"),
])
def test_wallet_hints_ignore_bad_unlinked_and_bank_evidence(vault, values, expected):
    db, source, destination = vault
    transaction(db, "debit")
    for index, value in enumerate(values):
        add_hint(db, str(index), value)
    add_hint(db, "bank", "Bank hint", source="bank")
    add_hint(db, "old", "Old hint", unlinked=True)
    db.commit()
    snapshot.export_snapshot(source, destination)
    assert jsonl(destination / "classifier_inputs.jsonl")[0]["input"].get("wallet_category_raw") == expected


def test_minimization_preserves_utf8_limits_even_when_replacements_expand(vault):
    db, source, destination = vault
    transaction(db, "debit", notes="1.00 " * 320)
    add_receipt(db, "receipt")
    add_ocr(db, "ocr", "receipt", "1.00 " * 320)
    db.commit()
    snapshot.export_snapshot(source, destination)
    value = jsonl(destination / "classifier_inputs.jsonl")[0]["input"]
    validate_input(value)
    assert len(value["transaction_notes"].encode()) <= 1600
    assert value["receipt_context"]["truncated"]
    context = snapshot.receipt_context(["界" * 1000])
    assert context["truncated"] and len(context["text"].encode()) <= 1600
    minimized = snapshot.sanitize("account 123456 fake@example.test +1 416 555 0100 2026-10-28 A1A 1A1 CAD 99.00")
    assert minimized == "[identifier] [email] [phone] [date] [postal-code] [amount]"


def test_output_path_existing_destination_and_encrypted_input_are_rejected(vault):
    db, source, destination = vault
    with pytest.raises(snapshot.SnapshotBlocked, match="inside"):
        snapshot.export_snapshot(source, destination.parent.parent.parent / "public")
    source.write_bytes(b"encrypted fixture")
    with pytest.raises(snapshot.SnapshotBlocked, match="encrypted"):
        snapshot.export_snapshot(source, destination)
    assert not destination.exists()
    destination.mkdir(parents=True)
    with pytest.raises(snapshot.SnapshotBlocked, match="already exists"):
        snapshot.export_snapshot(source, destination)


def test_empty_vault_has_explicit_zero_count(vault):
    _, source, destination = vault
    assert snapshot.export_snapshot(source, destination) == {"active_transactions": 0}
    assert jsonl(destination / "classifier_inputs.jsonl") == []


def test_privacy_denial_does_not_create_output_or_request_keys(vault, monkeypatch):
    _, source, destination = vault
    original_open = snapshot.Path.open

    def denied_open(path, *args, **kwargs):
        if path == source:
            raise PermissionError("fictional macOS privacy denial")
        return original_open(path, *args, **kwargs)

    monkeypatch.setattr(snapshot.Path, "open", denied_open)
    with pytest.raises(snapshot.SnapshotBlocked, match="macOS denied"):
        snapshot.export_snapshot(source, destination)
    assert not destination.exists()


def test_exact_app_inputs_preserve_raw_values_without_changing_original_export(vault):
    db, source, destination = vault
    raw_description = "Fictional Cafe https://example.test 1234567890"
    raw_notes = "Dinner CAD 25.00 fake@example.test"
    transaction(db, "debit", description=raw_description, notes=raw_notes)
    transaction(db, "credit", amount=1000, kind="refund", description="Fictional Refund")
    add_receipt(db, "receipt")
    add_ocr(db, "ocr", "receipt", "MILK 3.99\nVISA 1234\n123456789012")
    add_hint(db, "hint", "Food & Drink")
    db.commit()
    snapshot.export_snapshot(source, destination)
    before = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in destination.iterdir()}
    counts = snapshot.export_exact_inputs(destination)
    assert counts == {"active_transactions": 2, "changed_descriptions": 1, "changed_inputs": 1,
                      "with_transaction_notes": 1, "with_receipt_context": 1, "with_wallet_category_raw": 1}
    rows = jsonl(destination / "classifier_inputs.exact.jsonl")
    original = jsonl(destination / "classifier_inputs.jsonl")
    assert [r["id"] for r in rows] == [r["id"] for r in original]
    assert rows[0]["input"]["direction"] == "credit"
    assert rows[1]["input"]["description"] == raw_description
    assert rows[1]["input"]["transaction_notes"] == raw_notes
    assert rows[1]["input"]["receipt_context"]["text"] == "MILK 3.99"
    assert rows[1]["input"]["wallet_category_raw"] == "Food & Drink"
    assert rows[1]["split_groups"]["description"] != original[1]["split_groups"]["description"]
    assert set(rows[1]["input"]) == {"description", "direction", "currency", "transaction_notes", "receipt_context", "wallet_category_raw"}
    assert all(validate_input(row["input"]) for row in rows)
    assert before == {name: hashlib.sha256((destination / name).read_bytes()).hexdigest() for name in before}
    manifest = json.loads((destination / "classifier_inputs.exact.manifest.private.json").read_text())
    assert manifest["counts"] == counts
    assert len(manifest["app_construction_source_sha256"]) == 4
    assert manifest["exact_inputs_sha256"] == hashlib.sha256((destination / "classifier_inputs.exact.jsonl").read_bytes()).hexdigest()
    assert stat.S_IMODE((destination / "classifier_inputs.exact.jsonl").stat().st_mode) == 0o600
    with pytest.raises(snapshot.SnapshotBlocked, match="already exists"):
        snapshot.export_exact_inputs(destination)


def test_exact_input_derivation_refuses_changed_snapshot(vault):
    _, source, destination = vault
    snapshot.export_snapshot(source, destination)
    frozen = destination / "source.snapshot.sqlite"
    frozen.chmod(0o600)
    with frozen.open("ab") as stream:
        stream.write(b"changed-fictional-snapshot")
    with pytest.raises(snapshot.SnapshotBlocked, match="checksum mismatch"):
        snapshot.export_exact_inputs(destination)
    assert not (destination / "classifier_inputs.exact.jsonl").exists()


@pytest.mark.parametrize("merchant_name,payload_merchants,expected", [
    ("Fictional named merchant", ["Payload merchant"], "Fictional named merchant"),
    (None, ["Payload merchant", "Payload merchant", ""], "Payload merchant"),
    (None, ["Payload merchant", "Other merchant"], None),
    ("", ["Payload merchant"], ""),
])
def test_exact_search_candidates_follow_production_name_preference(vault, merchant_name, payload_merchants, expected):
    db, source, destination = vault
    overrides = {}
    if merchant_name is not None:
        put(db, "merchants", id="merchant", name=merchant_name, created_at_ms=0)
        overrides["merchant_id"] = "merchant"
    transaction(db, "debit", **overrides)
    put(db, "app_settings", key="merchant_search", value_json=json.dumps({"enabled": True, "locality": "Fictional City"}), updated_at_ms=0)
    for index, name in enumerate(payload_merchants):
        key = "merchant-event" + str(index)
        event(db, key)
        put(db, "raw_event_payloads", event_id=key, payload_json=json.dumps({"merchant": name}))
        link(db, key + "link", key, "debit")
    db.commit()
    snapshot.export_snapshot(source, destination)
    snapshot.export_exact_inputs(destination)
    record = jsonl(destination / "classifier_inputs.exact.jsonl")[0]
    assert record["search_merchant"] == expected
    assert record["search_locality"] == "Fictional City"
    assert set(record["input"]) == {"description", "direction", "currency"}
