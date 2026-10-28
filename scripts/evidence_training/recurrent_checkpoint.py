"""Training-only recomputation for MLX's sequential gated-delta recurrence."""

from contextlib import contextmanager


def chunked_recurrence(original, chunk_size=32):
    """Keep gradients through chunk boundaries; never shorten the sequence."""
    if chunk_size < 1:
        raise ValueError("chunk_size must be positive")
    import mlx.core as mx

    recompute = mx.checkpoint(original)

    def run(q, k, v, g, beta, state=None, mask=None):
        outputs = []
        for start in range(0, q.shape[1], chunk_size):
            end = start + chunk_size
            y, state = recompute(
                q[:, start:end], k[:, start:end], v[:, start:end],
                g[:, start:end], beta[:, start:end], state,
                None if mask is None else mask[:, start:end],
            )
            outputs.append(y)
        return mx.concatenate(outputs, axis=1), state

    return run


@contextmanager
def recurrent_checkpoints(chunk_size=32):
    from mlx_lm.models import gated_delta

    original = gated_delta.gated_delta_ops
    gated_delta.gated_delta_ops = chunked_recurrence(original, chunk_size)
    try:
        yield
    finally:
        gated_delta.gated_delta_ops = original

