"""Replay the app's immutable migrations and generate its browsable SQL reference.

This operates on fictional, in-memory databases, never a user's vault. Swift
remains responsible for production migration checksums, locking, and SQLCipher.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "apps/macos/GroundKeeperCore/Sources/GroundKeeperCore/Resources"
SNAPSHOT = ROOT / "contracts/database/schema.sql"


def migration_names():
    names = json.loads((RESOURCES / "migrations.json").read_text())
    if not names or any(
        not isinstance(name, str) or not re.fullmatch(rf"{version:03d}-[a-z0-9-]+", name)
        for version, name in enumerate(names, 1)
    ):
        raise ValueError("Invalid migration manifest")
    if {f"{name}.sql" for name in names} != {path.name for path in RESOURCES.glob("[0-9]*.sql")}:
        raise ValueError("Migration manifest must list every numbered SQL resource")
    return names


def apply_migrations(connection, through=None):
    """Install the manifest's migrations in app order, with deterministic metadata."""
    if connection.in_transaction:
        raise ValueError("Commit fixture data before applying migrations")
    names = migration_names()
    if through is not None and not 1 <= through <= len(names):
        raise ValueError("Unknown target migration")
    connection.execute("PRAGMA foreign_keys=ON")
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE name='schema_migrations'"
    ).fetchone()
    applied = dict(connection.execute("SELECT version,checksum FROM schema_migrations")) if exists else {}
    if any(version > len(names) for version in applied):
        raise ValueError("Database requires newer migrations")
    for version, name in enumerate(names[:through], 1):
        data = (RESOURCES / f"{name}.sql").read_bytes()
        checksum = hashlib.sha256(data).hexdigest()
        if version in applied:
            if applied[version] != checksum:
                raise ValueError("Migration checksum mismatch")
            continue
        # Match Database.migrate(): migration 001's transaction belongs to the runner.
        sql = data.decode().replace("\nBEGIN;", "").replace("\nCOMMIT;", "")
        try:
            connection.executescript("BEGIN IMMEDIATE;\n" + sql)
            connection.execute(
                "INSERT INTO schema_migrations VALUES (?,?,?,?)", (version, name, checksum, 0)
            )
            connection.commit()
        except Exception:
            connection.rollback()
            raise


def schema_snapshot():
    with sqlite3.connect(":memory:") as connection:
        apply_migrations(connection)
        lines = [
            "-- Generated from GroundKeeperCore/Resources/migrations.json and its SQL migrations.",
            "-- Do not edit. Regenerate: python -m scripts.database_schema",
            "-- Reference only; the app installs the numbered migrations, not this file.",
            "-- Includes initial reference data; excludes applied-migration records.",
            "",
        ]
        lines.extend(
            line for line in connection.iterdump()
            if not line.startswith('INSERT INTO "schema_migrations"')
        )
        return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if the checked-in reference is stale")
    args = parser.parse_args()
    generated = schema_snapshot()
    if args.check:
        if not SNAPSHOT.exists() or SNAPSHOT.read_text() != generated:
            raise SystemExit("Schema reference is stale. Run python -m scripts.database_schema")
    else:
        SNAPSHOT.write_text(generated)


if __name__ == "__main__":
    main()
