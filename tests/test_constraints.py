import json
import pytest
from groundkeeper.constraints import DecisionGrammar, allowed_answers
from groundkeeper.policy import validate_answer


class CharacterTokenizer:
    eos_token_ids = {0}
    def encode(self, text, **kwargs):
        return [ord(c) for c in text]
    def decode(self, tokens):
        return ''.join(chr(c) for c in tokens)


def test_every_complete_path_is_legal_and_all_legal_answers_are_reachable():
    tokenizer = CharacterTokenizer()
    grammar = DecisionGrammar(tokenizer)
    for text in allowed_answers():
        tokens = tokenizer.encode(text)
        for index, token in enumerate(tokens):
            assert token in grammar.allowed_tokens(tokens[:index])
        assert set(grammar.allowed_tokens(tokens)) == {0}
        validate_answer(json.loads(text))
    assert '{"type":"income","category":null,"review":false}' in grammar.answers
    assert not any('"category":"loan_principal"' in x for x in grammar.answers)
    assert '{"type":"unknown","category":"uncategorized","review":false}' not in grammar.answers
    assert not any('uncategorized' in answer for answer in grammar.answers)
    assert '{"type":"unknown","category":"other","review":true}' in grammar.answers
    for answer in map(json.loads, grammar.answers):
        if answer['type'] in ('expense', 'refund', 'unknown'):
            assert answer['category'] is not None


def test_invalid_prefix_and_content_after_eos_fail_closed():
    grammar = DecisionGrammar(CharacterTokenizer())
    with pytest.raises(ValueError):
        grammar.allowed_tokens([ord('x')])
    tokens = CharacterTokenizer().encode(grammar.answers[0])
    with pytest.raises(ValueError):
        grammar.allowed_tokens(tokens + [0])


def test_field_order_can_match_existing_training_without_changing_decisions():
    first = {tuple(sorted(json.loads(s).items())) for s in allowed_answers()}
    other = {tuple(sorted(json.loads(s).items())) for s in allowed_answers(('category','review','type'))}
    assert first == other
    with pytest.raises(ValueError):
        allowed_answers(('type','type','review'))


@pytest.mark.gpu
def test_logits_outside_the_current_branch_are_masked(mlx_gpu):
    mx = mlx_gpu
    grammar = DecisionGrammar(CharacterTokenizer())
    logits = mx.arange(128, dtype=mx.float32)[None, :]
    masked = grammar.processor(2)(mx.array([1, 2]), logits)
    assert mx.isfinite(masked).sum().item() == 1
    assert mx.argmax(masked).item() == ord('{')
    # MLX's internal one-token lookahead must safely absorb a legal EOS.
    tokens = [1, 2] + CharacterTokenizer().encode(grammar.answers[0]) + [0]
    terminal = grammar.processor(2)(mx.array(tokens), logits)
    assert mx.isfinite(terminal).sum().item() == 1
    assert mx.argmax(terminal).item() == 0
    with pytest.raises(ValueError):
        grammar.processor(2)(mx.array([1, 2, 0]), logits)
