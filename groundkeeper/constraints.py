"""Finite JSON grammar for the complete transaction decision contract.

Every successful completion is one of the schema-valid canonical JSON objects.
This constrains structure and field combinations, not semantic correctness.
No private input, model call or external service is used to build the grammar.
"""
import json
from .policy import TYPES, CATEGORIES, validate_answer


def allowed_answers(key_order=('type', 'category', 'review')):
    if len(key_order) != 3 or set(key_order) != {'type','category','review'}:
        raise ValueError('Expected each output field exactly once')
    answers = []
    for typ in TYPES:
        for category in (*CATEGORIES, None):
            for review in (False, True):
                answer = {'type': typ, 'category': category, 'review': review}
                try:
                    validate_answer(answer)
                except ValueError:
                    continue
                answers.append(json.dumps({key:answer[key] for key in key_order}, separators=(',', ':')))
    return tuple(answers)


class DecisionGrammar:
    def __init__(self, tokenizer, key_order=('type','category','review')):
        self.root = {}
        self.max_answer_tokens = 0
        self.answers = allowed_answers(key_order)
        self.key_order = tuple(key_order)
        self.eos = set(tokenizer.eos_token_ids)
        if not self.eos:
            raise ValueError('An explicit stop token is required')
        for answer in self.answers:
            encoded = tokenizer.encode(answer, add_special_tokens=False)
            if tokenizer.decode(encoded) != answer:
                raise ValueError('Tokenizer cannot round-trip canonical JSON')
            if any(token in self.eos for token in encoded):
                raise ValueError('Stop token in an answer')
            self.max_answer_tokens = max(self.max_answer_tokens, len(encoded))
            node = self.root
            for token in encoded:
                node = node.setdefault(token, {})
            for token in self.eos:
                node[token] = None

    def allowed_tokens(self, suffix):
        node = self.root
        for token in suffix:
            if node is None or token not in node:
                raise ValueError('Generation left the JSON grammar')
            node = node[token]
        if node is None:
            raise ValueError('Generation continued after a stop token')
        return tuple(node)

    def processor(self, prompt_length):
        if prompt_length < 1:
            raise ValueError('Expected a nonempty tokenized prompt')

        def mask(tokens, logits):
            import mlx.core as mx
            if len(tokens) < prompt_length:
                raise ValueError('Incomplete prompt passed to grammar')
            suffix = tokens[prompt_length:].tolist()
            # MLX computes one token ahead before yielding EOS to the caller.
            # Permit only EOS for that internal step after a complete answer.
            if suffix and suffix[-1] in self.eos:
                if suffix[-1] not in self.allowed_tokens(suffix[:-1]):
                    raise ValueError('Premature stop token')
                allowed = tuple(self.eos)
            else:
                allowed = self.allowed_tokens(suffix)
            masked = mx.full(logits.shape, -float('inf'), dtype=logits.dtype)
            indices = mx.array(allowed)
            masked[..., indices] = logits[..., indices]
            return masked

        return mask


def generate_constrained(model, tokenizer, inputs, grammar=None, message_builder=None):
    import time
    import mlx.core as mx
    from mlx_lm import generate
    from mlx_lm.sample_utils import make_sampler
    from .policy import messages, parse_answer
    grammar = grammar or DecisionGrammar(tokenizer)
    builder = message_builder or messages
    prompt = tokenizer.apply_chat_template(
        builder(inputs), tokenize=True, add_generation_prompt=True,
        enable_thinking=False, return_dict=False)
    start = time.monotonic()
    text = generate(model, tokenizer, prompt=mx.array(prompt),
                    max_tokens=grammar.max_answer_tokens + 2,
                    sampler=make_sampler(0),
                    logits_processors=[grammar.processor(len(prompt))])
    if text not in grammar.answers:
        raise ValueError('Constrained generation failed to complete a legal answer')
    answer = parse_answer(text)
    return answer, {'raw': text, 'valid_schema': True, 'removed_json_fence': False,
                    'latency_seconds': time.monotonic() - start,
                    'decoder': 'finite_canonical_json_v1', 'key_order': grammar.key_order}
