"""Guard the installed migration chain and its generated documentation."""

import hashlib
import sqlite3

import pytest

from scripts.database_schema import RESOURCES, SNAPSHOT, apply_migrations, migration_names, schema_snapshot
from test_database_schema import put, transaction


def test_schema_reference_is_generated_from_the_installed_migrations():
    assert SNAPSHOT.read_text() == schema_snapshot()


def test_migration_history_records_original_file_checksums_and_replay_is_idempotent():
    with sqlite3.connect(":memory:") as db:
        apply_migrations(db)
        expected = [
            (version, name, hashlib.sha256((RESOURCES / f"{name}.sql").read_bytes()).hexdigest())
            for version, name in enumerate(migration_names(), 1)
        ]
        assert db.execute("SELECT version,name,checksum FROM schema_migrations ORDER BY version").fetchall() == expected
        apply_migrations(db)
        assert db.execute("SELECT count(*) FROM schema_migrations").fetchone() == (len(expected),)
        db.execute("UPDATE schema_migrations SET checksum='changed' WHERE version=1")
        db.commit()
        with pytest.raises(ValueError, match="checksum mismatch"):
            apply_migrations(db)


def test_upgrade_records_existing_pending_payments_and_preserves_amounts():
    with sqlite3.connect(":memory:") as db:
        apply_migrations(db, through=11)
        put(db, "accounts", id="card", name="Fictional card", kind="credit_card", currency="CAD", created_at_ms=0)
        transaction(db, lifecycle="pending")
        db.commit()
        apply_migrations(db)
        assert db.execute("SELECT lifecycle,amount_minor,occurred_on FROM transactions").fetchone() == (
            "posted", -1250, "2026-10-17"
        )
        assert db.execute("PRAGMA foreign_key_check").fetchall() == []
