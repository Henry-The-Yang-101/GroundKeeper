import pytest

from scripts.full_common import choose_checkpoint


def report(step, macro=0.6, joint=0.5, invalid=3):
    return {'step': step, 'invalid_outputs': invalid,
            'metrics': {'macro_f1_supported_categories': macro, 'joint_accuracy': joint}}


def test_macro_precedes_accuracy_and_then_fixed_ties():
    rows = [report(128, joint=0.9), report(256, macro=0.61),
            report(384, macro=0.61, joint=0.6, invalid=4),
            report(512, macro=0.61, joint=0.6), report(632, macro=0.61, joint=0.6)]
    assert choose_checkpoint(rows)['step'] == 512


def test_missing_or_duplicate_checkpoint_cannot_unlock_test():
    with pytest.raises(ValueError):
        choose_checkpoint([report(128)])
    with pytest.raises(ValueError):
        choose_checkpoint([report(i) for i in [128, 256, 384, 512, 512]])
