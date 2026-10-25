"""Protocol/security tests without loading models or using held-out data."""
import hashlib
import json

import pytest

from groundkeeper.worker import Worker, POLICY_VERSION, WorkerError, verify_package


def request(operation="handshake", **values):
    return {"protocol_version": 1, "request_id": "request-1", "operation": operation, **values}


def package(tmp_path, **values):
    root = tmp_path / "package"
    root.mkdir()
    (root / "model").mkdir()
    content = b'{"model_type":"fixture"}'
    (root / "model/config.json").write_bytes(content)
    manifest = {"format_version": 1, "model_id": "test", "backend": "qwen_mlx",
                "policy_version": POLICY_VERSION, "model_directory": "model",
                "files": {"model/config.json": {"bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}},
                **values}
    (root / "classifier.json").write_text(json.dumps(manifest))
    return root


def test_handshake_without_loading_ml_libraries(monkeypatch):
    monkeypatch.setattr("importlib.metadata.version", lambda name: "test")
    worker = Worker()
    result = worker.handle(request())
    assert result["result"]["backends"] == ["qwen_mlx", "laya_mps", "apple_shortcut"]
    assert result["result"]["loaded_model"] is None
    assert result["result"]["gpu_required"] is True
    assert result["result"]["policy_version"] == "groundkeeper-19-v2"
    assert len(result["result"]["categories"]) == 19
    assert "uncategorized" not in result["result"]["categories"]


def test_existing_package_manifest_remains_loadable_under_new_runtime_policy(tmp_path):
    root = package(tmp_path, policy_version="groundkeeper-18-v1")
    before = (root / "classifier.json").read_bytes()
    manifest, digest = verify_package(root, lambda: False)
    assert manifest["policy_version"] == "groundkeeper-18-v1"
    assert digest == hashlib.sha256(before).hexdigest()
    assert (root / "classifier.json").read_bytes() == before


@pytest.mark.parametrize("value,code", [
    (None, "incompatible_protocol"), (request(protocol_version=2), "incompatible_protocol"),
    (request(protocol_version=True), "incompatible_protocol"),
    (request(operation="eval"), "unsupported_operation"), (request(request_id=""), "invalid_request"),
    (request(operation="classify"), "model_not_ready"),
])
def test_invalid_or_unprepared_requests(value, code):
    result = Worker().handle(value)
    assert result["status"] == "failed"
    assert result["error"]["code"] == code


def test_cancelled_request_never_loads_model():
    worker = Worker()
    assert worker.handle(request("prepare_model"), lambda: True)["error"]["code"] == "cancelled"
    assert worker.model is None


def test_no_caller_supplied_package_path_in_python_request(tmp_path):
    result = Worker().handle(request("prepare_model", package_root=str(tmp_path)))
    assert result["error"]["code"] == "invalid_package"


def test_package_integrity_and_model_identity(tmp_path):
    root = package(tmp_path)
    manifest, digest = verify_package(root, lambda: False)
    assert manifest["model_id"] == "test"
    assert digest == hashlib.sha256((root / "classifier.json").read_bytes()).hexdigest()
    (root / "model/config.json").write_text("changed")
    with pytest.raises(WorkerError, match="mismatch"):
        verify_package(root, lambda: False)


def test_manifest_counts_towards_model_size_limit(monkeypatch, tmp_path):
    root = package(tmp_path)
    monkeypatch.setattr("groundkeeper.worker.MAX_PACKAGE_BYTES", (root / "classifier.json").stat().st_size)
    with pytest.raises(WorkerError, match="limit"):
        verify_package(root, lambda: False)


def test_extra_executable_content_and_symlink_escape_rejected(tmp_path):
    root = package(tmp_path)
    (root / "malicious.py").write_text("raise RuntimeError('never execute')")
    with pytest.raises(WorkerError, match="Unexpected"):
        verify_package(root, lambda: False)
    (root / "malicious.py").unlink()
    outside = tmp_path / "outside.json"
    outside.write_text("{}")
    (root / "model/config.json").unlink()
    (root / "model/config.json").symlink_to(outside)
    with pytest.raises(WorkerError, match="outside"):
        verify_package(root, lambda: False)


def prepared_worker():
    worker = Worker()
    worker.model = object()
    worker.manifest = {"backend": "qwen_mlx"}
    worker.identity = {"model_id": "fixture", "manifest_sha256": "a" * 64}
    return worker


def classify_request(**values):
    return request("classify", model_manifest_sha256="a" * 64, policy_version=POLICY_VERSION,
        job_id="job", part_id="part", transaction_revision=3,
        input={"description": "Fictional Cafe", "direction": "debit", "currency": "CAD"}, **values)


def test_identity_revision_and_review_are_preserved(monkeypatch):
    worker = prepared_worker()
    monkeypatch.setattr(worker, "qwen", lambda *_: {"type": "expense", "category": "dining", "review": False})
    result = worker.handle(classify_request())["result"]
    assert result["decision"] == {"type": "expense", "category": "dining", "review": True}
    assert result["part_id"] == "part"
    assert result["job_id"] == "job"
    assert result["transaction_revision"] == 3


@pytest.mark.parametrize("field,value,code", [
    ("model_manifest_sha256", "another-model", "model_mismatch"),
    ("policy_version", "another-policy", "incompatible_policy"),
    ("transaction_revision", True, "invalid_request"),
    ("transaction_revision", 0, "invalid_request"),
    ("input", {"description": "x" * 2049, "direction": "debit", "currency": "CAD"}, "input_too_large"),
    ("input", {"description": "Cafe", "direction": "debit", "currency": "CAD", "latitude": 43}, "invalid_request"),
])
def test_bad_inputs_do_not_reach_inference(field, value, code):
    worker = prepared_worker()
    request = classify_request()
    request[field] = value
    assert worker.handle(request)["error"]["code"] == code


def test_dependency_errors_never_echo_financial_input(monkeypatch):
    worker = prepared_worker()
    def fail(*_):
        raise RuntimeError("SECRET TRANSACTION BODY")
    monkeypatch.setattr(worker, "qwen", fail)
    result = worker.handle(classify_request())
    assert result["error"]["code"] == "inference_failed"
    assert "SECRET" not in json.dumps(result)


def test_gpu_unavailable_is_explicit_not_cpu_fallback(monkeypatch, tmp_path):
    import sys
    from types import SimpleNamespace
    fake = SimpleNamespace(metal=SimpleNamespace(is_available=lambda: False))
    monkeypatch.setitem(sys.modules, "mlx", SimpleNamespace(core=fake))
    monkeypatch.setitem(sys.modules, "mlx.core", fake)
    worker = Worker()
    root = package(tmp_path)
    result = worker.handle(request("prepare_model"), package_root=root)
    assert result["error"]["code"] == "gpu_unavailable"
    assert worker.model is None


@pytest.mark.parametrize("backend", ["qwen_mlx", "laya_mps"])
def test_partial_load_releases_tensors_before_clearing_cache(monkeypatch, tmp_path, backend):
    import sys
    import weakref
    from contextlib import nullcontext
    from types import SimpleNamespace

    references, cleared = [], []
    class Tensor:
        pass
    def allocate():
        tensor = Tensor()
        references.append(weakref.ref(tensor))
        raise RuntimeError("partial allocation")
    def fail(*args, **kwargs):
        try:
            allocate()
        except RuntimeError as error:
            raise RuntimeError("wrapped loader error") from error
    def clear():
        assert references and references[0]() is None
        cleared.append(backend)
    mx = SimpleNamespace(metal=SimpleNamespace(is_available=lambda: True), gpu=object(),
        set_default_device=lambda _: None, set_cache_limit=lambda _: None,
        set_memory_limit=lambda _: None, stream=lambda _: nullcontext(),
        synchronize=lambda: None, clear_cache=clear)
    torch = SimpleNamespace(backends=SimpleNamespace(mps=SimpleNamespace(is_available=lambda: True)),
        set_num_threads=lambda _: None, mps=SimpleNamespace(synchronize=lambda: None, empty_cache=clear))
    monkeypatch.setitem(sys.modules, "mlx", SimpleNamespace(core=mx))
    monkeypatch.setitem(sys.modules, "mlx.core", mx)
    monkeypatch.setitem(sys.modules, "mlx_lm", SimpleNamespace(load=fail))
    monkeypatch.setitem(sys.modules, "torch", torch)
    monkeypatch.setattr("groundkeeper.laya_runtime.LocalLayaCategorizer", fail)
    monkeypatch.setattr("groundkeeper.worker.verify_package", lambda *_: ({"backend": backend}, "digest"))
    worker = Worker()
    result = worker.handle(request("prepare_model"), package_root=tmp_path)
    assert result["error"]["code"] == "inference_failed"
    assert cleared == [backend]
    assert worker.model is None and worker._allocated_backend is None
    worker.release()
    assert cleared == [backend]


def test_shortcut_provider_preserves_identity_and_requires_review(monkeypatch):
    monkeypatch.setattr('groundkeeper.apple_shortcuts.run_shortcut',
        lambda *a, **k: ({'type': 'expense', 'category': 'dining', 'review': False}, {}))
    worker = Worker()
    model = worker.handle(request('prepare_shortcut', shortcut_name='Fixture'))['result']['model']
    values = dict(policy_version=POLICY_VERSION, model_manifest_sha256=model['manifest_sha256'],
                  part_id='part', job_id='job', transaction_revision=2,
                  input={'description': 'Fictional cafe', 'direction': 'debit', 'currency': 'CAD'})
    result = worker.handle(request('classify', **values))['result']
    assert result['decision']['review'] is True
    assert result['job_id'] == 'job' and result['transaction_revision'] == 2
    assert result['model'] == model
    other = worker.handle(request('prepare_shortcut', shortcut_name='Other'))['result']['model']
    assert other['manifest_sha256'] != model['manifest_sha256']
    assert worker.handle(request('classify', **values))['error']['code'] == 'model_mismatch'


def test_shortcut_error_does_not_expose_private_logs(monkeypatch):
    from groundkeeper.apple_shortcuts import ShortcutExecutionError
    def fail(*a, **k):
        raise ShortcutExecutionError('private input', {'status': 'execution_error'})
    monkeypatch.setattr('groundkeeper.apple_shortcuts.run_shortcut', fail)
    worker = Worker()
    model = worker.handle(request('prepare_shortcut', shortcut_name='Fixture'))['result']['model']
    result = worker.handle(request('classify', policy_version=POLICY_VERSION,
        model_manifest_sha256=model['manifest_sha256'], part_id='p', job_id='j', transaction_revision=1,
        input={'description': 'Private merchant', 'direction': 'debit', 'currency': 'CAD'}))
    assert result['error']['code'] == 'shortcut_unavailable'
    assert 'private' not in json.dumps(result).lower()
