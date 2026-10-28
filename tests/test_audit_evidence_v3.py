import pytest

from scripts.audit_evidence_v3 import family_plan


def row(ident, original, proposed, split):
    return {"id": ident, "merchant_family": original, "split": split,
            "label": {"merchant_family_proposed": proposed}}


def test_researched_alias_cannot_leak_old_holdout_into_training():
    records = [row("train-1", "old-acronym", "Fictional Holdings", "train")]
    historical = [{"merchant_family": "Fictional Holdings", "split": "test"}]
    plan = family_plan(records, historical)
    assert plan[0]["status"] == "quarantine_cross_split"
    assert plan[0]["split"] is None
    assert plan[0]["historical_splits"] == ["test", "train"]


def test_transitive_aliases_union_and_unrelated_unknowns_stay_separate():
    records = [row("a", "name-one", "name-two", "train"),
               row("b", "name-two", "name-three", "train"),
               row("c", "unknown:abc", "unknown:abc", "valid"),
               row("d", "unknown:xyz", "unknown:xyz", "test")]
    plan = family_plan(records, [])
    assert len(plan) == 3
    group = next(p for p in plan if "a" in p["ids"])
    assert sorted(group["ids"]) == ["a", "b"]
    assert group["status"] == "consistent"


def test_blank_research_family_rejected():
    with pytest.raises(ValueError):
        family_plan([row("x", "original", "", "train")], [])
