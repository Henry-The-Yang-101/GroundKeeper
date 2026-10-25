import pytest

from groundkeeper.laya_runtime import CATEGORY_CRITERIA, DECISIONS, NULL, QUESTIONS, TYPE_CRITERIA, decode, training_row
from groundkeeper.policy import CATEGORIES, TYPES, validate_answer


def distributions(typ="expense", cat="dining", review="false"):
    chosen = {"type": typ, "category": cat, "review": review}
    return {field: {"choice": chosen[field], "probabilities": {
        key: 0.9 if key == chosen[field] else 0.1 / (len(q["criteria"]) - 1)
        for key in q["criteria"]}} for field, q in QUESTIONS.items()}


def test_contract_coverage_and_round_trip():
    assert set(TYPE_CRITERIA) == set(TYPES)
    assert set(CATEGORY_CRITERIA) == set(CATEGORIES) | {NULL}
    for answer in DECISIONS:
        expected = training_row({"id": "synthetic", "input": {
            "description": "test", "direction": "unknown", "currency": "CAD"}, "answer": answer})["expected"]
        prediction, detail = decode(distributions(expected["type"], expected["category"], expected["review"]))
        assert prediction == answer
        assert detail["raw_valid_schema"]


def test_joint_decode_resolves_incompatible_fields_without_invalid_json():
    answer, detail = decode(distributions("income", "dining", "false"))
    validate_answer(answer)
    assert not detail["raw_valid_schema"]
    assert detail["constraint_changed"]


@pytest.mark.parametrize("bad", [None, float("nan"), float("inf"), -0.1, 1.1])
def test_bad_distribution_fails_closed(bad):
    answers = distributions()
    answers["category"]["probabilities"]["dining"] = bad
    answer, detail = decode(answers)
    assert answer == {"type": "unknown", "category": "other", "review": True}
    assert not detail["valid_schema"]


def test_missing_option_fails_closed():
    answers = distributions()
    del answers["category"]["probabilities"]["other"]
    answer, detail = decode(answers)
    assert answer["review"]
    assert not detail["valid_schema"]


@pytest.mark.parametrize("fails", [False, True])
def test_package_tokenizer_cache_evicted_after_load(monkeypatch, tmp_path, fails):
    import sys
    import threading
    from types import SimpleNamespace
    import groundkeeper.laya_runtime as runtime

    (tmp_path / "model.safetensors").touch()
    directory = str(tmp_path / "tokenizer")
    tokenizer = object()
    cache = {(directory, 1): tokenizer, (directory, 2): tokenizer, ("unrelated", 1): object()}
    device = SimpleNamespace(type="mps")
    agent = SimpleNamespace(tok=tokenizer, device=device,
        model=SimpleNamespace(parameters=lambda: iter([SimpleNamespace(device=device)])))
    def load(*args, **kwargs):
        if fails:
            raise RuntimeError("failed loading")
        return agent
    monkeypatch.setitem(sys.modules, "laya", SimpleNamespace(load=load,
        agent=SimpleNamespace(_TOKENIZERS=cache, _TOKENIZERS_LOCK=threading.Lock())))
    monkeypatch.setattr(runtime, "configure_agent", lambda value: value)
    if fails:
        with pytest.raises(RuntimeError, match="failed loading"):
            runtime.LocalLayaCategorizer(tmp_path)
    else:
        loaded = runtime.LocalLayaCategorizer(tmp_path)
        assert loaded.agent.tok is tokenizer
    assert set(cache) == {("unrelated", 1)}
