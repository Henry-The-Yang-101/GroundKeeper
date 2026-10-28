import pytest

mx = pytest.importorskip("mlx.core")
from mlx_lm.models.gated_delta import gated_delta_ops

from scripts.evidence_training.recurrent_checkpoint import chunked_recurrence


@pytest.mark.parametrize("masked,vector_gate", [(False, False), (True, False), (True, True), (False, True)])
def test_recomputation_preserves_outputs_and_gradients(masked, vector_gate):
    mx.random.seed(123)
    q = mx.random.normal((1, 65, 1, 4)) * .1
    k = mx.random.normal((1, 65, 1, 4)) * .1
    v = mx.random.normal((1, 65, 2, 3)) * .1
    g = mx.full((1, 65, 2, 4) if vector_gate else (1, 65, 2), .9)
    beta = mx.full((1, 65, 2), .4)
    state = mx.random.normal((1, 2, 3, 4)) * .1
    mask = (mx.arange(65)[None] < 50) if masked else None
    args = (q, k, v, g, beta, state)
    chunked = chunked_recurrence(gated_delta_ops, 32)
    expected = gated_delta_ops(*args, mask)
    actual = chunked(*args, mask)
    for a, b in zip(actual, expected):
        assert mx.allclose(a, b, atol=1e-6, rtol=1e-5).item()

    def loss(fn, *values):
        y, final = fn(*values, mask)
        return mx.sum(y * y) + mx.sum(final * final)

    ref_grad = mx.grad(lambda *xs: loss(gated_delta_ops, *xs), argnums=tuple(range(6)))(*args)
    got_grad = mx.grad(lambda *xs: loss(chunked, *xs), argnums=tuple(range(6)))(*args)
    for a, b in zip(got_grad, ref_grad):
        assert mx.allclose(a, b, atol=1e-5, rtol=1e-4).item()


def test_recomputation_handles_initial_zero_state():
    q = mx.ones((1, 33, 1, 4)) * .1
    v = mx.ones((1, 33, 1, 3)) * .2
    g = mx.full((1, 33, 1), .9)
    beta = mx.full((1, 33, 1), .4)
    for a, b in zip(chunked_recurrence(gated_delta_ops)(q, q, v, g, beta),
                    gated_delta_ops(q, q, v, g, beta)):
        assert mx.allclose(a, b).item()

