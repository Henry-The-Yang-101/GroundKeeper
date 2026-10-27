"""Upgrade legacy category history without relabeling past AI decisions."""

import json
import sqlite3

import pytest
from test_database_schema import assignment, model_run, put, setup_models, transaction

from scripts.database_schema import apply_migrations


def test_legacy_category_upgrade_retains_history_and_original_model_output():
    db = sqlite3.connect(":memory:")
    apply_migrations(db, through=9)
    put(
        db,
        "accounts",
        id="card",
        name="Fictional card",
        kind="credit_card",
        currency="CAD",
        created_at_ms=0,
    )
    transaction(db, category="uncategorized", kind="unknown", origin="system")
    setup_models(db)
    raw = json.dumps({"type": "unknown", "category": "uncategorized", "review": True})
    model_run(db, type_code="unknown", category_id="uncategorized", output_json=raw)
    assignment(
        db,
        "ai",
        "t1p",
        kind="unknown",
        category="uncategorized",
        origin="model",
        run_id="r1",
        supersedes_id="t1a",
    )
    assignment(
        db,
        "confirmed",
        "t1p",
        kind="unknown",
        category="uncategorized",
        origin="user",
        supersedes_id="ai",
    )
    db.execute("UPDATE transaction_parts SET current_assignment_id='confirmed'")
    put(
        db,
        "user_rules",
        id="rule",
        name="Legacy",
        version=1,
        priority=1,
        predicate_json="{}",
        type_code="unknown",
        category_id="uncategorized",
        confirmed_at_ms=0,
    )
    put(
        db,
        "model_categories",
        model_version_id="qwen",
        output_label="uncategorized",
        category_id="uncategorized",
    )
    db.commit()
    apply_migrations(db, through=10)
    assert db.execute("SELECT count(*) FROM categories").fetchone() == (19,)
    assert db.execute(
        "SELECT count(*) FROM category_assignments WHERE category_id IS NULL"
    ).fetchone() == (3,)
    assert db.execute(
        "SELECT supersedes_id,origin,confirmed_by FROM category_assignments WHERE id='confirmed'"
    ).fetchone() == ("ai", "user", "local_user")
    assert db.execute("SELECT current_assignment_id FROM transaction_parts").fetchone() == (
        "confirmed",
    )
    assert db.execute(
        "SELECT category_id,model_version_id,output_json FROM classification_runs"
    ).fetchone() == (None, "qwen", raw)
    assert db.execute("SELECT category_id FROM user_rules").fetchone() == (None,)
    assert db.execute("SELECT * FROM model_categories").fetchall() == []
    assert db.execute("PRAGMA foreign_key_check").fetchall() == []
    assert db.execute("PRAGMA integrity_check").fetchone() == ("ok",)
    with pytest.raises(sqlite3.IntegrityError, match="append a new assignment"):
        db.execute("UPDATE category_assignments SET category_id='other' WHERE id='ai'")
    with pytest.raises(sqlite3.IntegrityError, match="missing category must be NULL"):
        put(
            db,
            "categories",
            id="legacy",
            code="uncategorized",
            name="Legacy",
            kind="spending",
            created_at_ms=0,
        )
    with pytest.raises(sqlite3.IntegrityError, match="AI spending decisions require a category"):
        model_run(db, key="bad", type_code="expense", category_id=None)
    model_run(db, key="current", type_code="unknown", category_id="other")
    assignment(
        db,
        "current-ai",
        "t1p",
        kind="unknown",
        category="other",
        origin="model",
        run_id="current",
        needs_review=1,
    )
    db.commit()
    apply_migrations(db)
    assert db.execute("SELECT current_assignment_id FROM transaction_parts").fetchone() == (
        "unassigned-v11:confirmed",
    )
    assert db.execute(
        "SELECT origin,supersedes_id,needs_review FROM category_assignments WHERE id='unassigned-v11:confirmed'"
    ).fetchone() == ("system", "confirmed", 1)
    assert db.execute(
        "SELECT origin,confirmed_by FROM category_assignments WHERE id='confirmed'"
    ).fetchone() == ("user", "local_user")
    db.close()
