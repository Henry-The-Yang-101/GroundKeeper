"""Optional accelerator fixtures never import a backend during collection."""

import sys

import pytest


@pytest.fixture
def mlx_gpu():
    if sys.platform != "darwin":
        pytest.skip("MLX Metal tests require macOS")
    mx = pytest.importorskip("mlx.core")
    pytest.importorskip("mlx_lm")
    if not mx.metal.is_available():
        pytest.skip("MLX Metal device unavailable")
    return mx


@pytest.fixture
def torch_mps():
    torch = pytest.importorskip("torch")
    if not torch.backends.mps.is_available():
        pytest.skip("PyTorch MPS device unavailable")
    return torch
