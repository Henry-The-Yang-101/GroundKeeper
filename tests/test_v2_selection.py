import pytest

from scripts.v2_common import checkpoint_steps, choose


def result(candidate, step, macro=0.6, joint=0.5):
    return {
        "candidate": candidate,
        "step": step,
        "invalid_outputs": 0,
        "metrics": {"macro_f1_supported_categories": macro, "joint_accuracy": joint},
    }


def test_schedule_finishes_complete_updates_and_rounds_up_one_pass():
    for n in (625, 626, 1701, 2200, 2899):
        steps = checkpoint_steps(n)
        assert len(steps) == 3 and all(s % 8 == 0 for s in steps)
        assert n <= steps[-1] < n + 8


def test_selection_requires_both_candidates_and_each_saved_checkpoint():
    steps = [8, 16, 24]
    rows = [result(c, s) for c in (0, 1) for s in steps]
    rows[-1]["metrics"]["macro_f1_supported_categories"] = 0.61
    assert choose(rows, steps) == rows[-1]
    with pytest.raises(ValueError):
        choose(rows[:-1], steps)
    with pytest.raises(ValueError):
        choose(rows + [rows[-1]], steps)


def test_ties_choose_earlier_checkpoint_then_first_candidate():
    rows = [result(c, s) for c in (1, 0) for s in (24, 16, 8)]
    selected = choose(rows, [8, 16, 24])
    assert (selected["candidate"], selected["step"]) == (0, 8)
