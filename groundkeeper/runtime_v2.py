"""Local structured decision runtime with explicit constrained decoding modes."""

import time

from .constraints import DecisionGrammar, generate_constrained
from .policy import messages, parse_answer
from .policy_v2 import messages_v2


def _generate_draft(model, tokenizer, inputs, message_builder):
    """Keep optional MLX imports at the backend boundary."""
    import mlx.core as mx
    from mlx_lm import generate
    from mlx_lm.sample_utils import make_sampler

    prompt = tokenizer.apply_chat_template(
        message_builder(inputs),
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=False,
        return_dict=False,
    )
    return generate(
        model, tokenizer, prompt=mx.array(prompt), max_tokens=96, sampler=make_sampler(0)
    )


def generate_decision(
    model, tokenizer, inputs, grammar=None, mode="constrained", message_builder=messages_v2
):
    """Return validated JSON; a failed constrained completion raises explicitly.

    The retry mode preserves valid first-pass answers and constrains a second
    generation only when the first violates the schema. It reports both stages.
    """
    grammar = grammar or DecisionGrammar(tokenizer)
    start = time.monotonic()
    if mode == "constrained":
        answer, detail = generate_constrained(model, tokenizer, inputs, grammar, message_builder)
        return answer, {**detail, "mode": mode, "draft_invalid": False, "constrained_retry": False}
    if mode != "validated_retry":
        raise ValueError("Unsupported generation mode")
    draft = _generate_draft(model, tokenizer, inputs, message_builder)
    try:
        answer = parse_answer(draft)
        return answer, {
            "raw": draft,
            "valid_schema": True,
            "latency_seconds": time.monotonic() - start,
            "mode": mode,
            "draft_invalid": False,
            "constrained_retry": False,
            "removed_json_fence": draft.strip().startswith("```"),
        }
    except (ValueError, TypeError):
        answer, detail = generate_constrained(model, tokenizer, inputs, grammar, message_builder)
        return answer, {
            **detail,
            "mode": mode,
            "draft_invalid": True,
            "constrained_retry": True,
            "draft_raw": draft,
            "latency_seconds": time.monotonic() - start,
        }


class StructuredCategorizer:
    def __init__(self, model_path, adapter_path=None, mode="constrained", prompt_version="v2"):
        if mode not in ("constrained", "validated_retry") or prompt_version not in ("v1", "v2"):
            raise ValueError("Unsupported structured runtime configuration")
        import mlx.core as mx

        mx.set_memory_limit(14_000_000_000)
        mx.set_cache_limit(512_000_000)
        from .runtime import LocalCategorizer

        loaded = LocalCategorizer(model_path, adapter_path)
        self.model, self.tokenizer = loaded.model, loaded.tokenizer
        self.grammar = DecisionGrammar(self.tokenizer)
        self.mode = mode
        self.builder = messages if prompt_version == "v1" else messages_v2

    def suggest(self, inputs):
        answer, _ = generate_decision(
            self.model, self.tokenizer, inputs, self.grammar, self.mode, self.builder
        )
        return {**answer, "review": True}
