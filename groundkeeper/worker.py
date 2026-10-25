"""Local inference boundary hosted by the bundled native XPC service.

No database, network, arbitrary Python evaluation, or caller-supplied model code.
One instance is confined to the service's dedicated inference thread.
"""
from __future__ import annotations

import gc
import hashlib
import importlib.metadata
import json
import math
import os
from pathlib import Path
import time
import traceback

from .policy import CATEGORIES, TYPES, validate_answer, validate_input

PROTOCOL_VERSION = 1
POLICY_VERSION = "groundkeeper-19-v2"
MAX_DESCRIPTION = 2048
MAX_PACKAGE_BYTES = 3_000_000_000


class WorkerError(Exception):
    def __init__(self, code, message):
        self.code, self.message = code, message
        super().__init__(message)


def _check(cancelled):
    if cancelled():
        raise WorkerError("cancelled", "Request cancelled or deadline exceeded")


def _clear_exception_frames(error):
    pending, seen = [error], set()
    while pending:
        current = pending.pop()
        if id(current) in seen:
            continue
        seen.add(id(current))
        traceback.clear_frames(current.__traceback__)
        pending.extend(e for e in (current.__cause__, current.__context__) if e is not None)
        if isinstance(current, BaseExceptionGroup):
            pending.extend(current.exceptions)


def _relative(root, value):
    if not isinstance(value, str) or not value or Path(value).is_absolute():
        raise WorkerError("invalid_package", "Expected relative package file")
    path = (root / value).resolve()
    if not path.is_relative_to(root) or not path.is_file():
        raise WorkerError("invalid_package", "Package file missing or outside package")
    return path


def verify_package(root: Path, cancelled):
    """Verify data before loading; never import Python from a model package."""
    manifest_path = root / "classifier.json"
    if not manifest_path.is_file() or manifest_path.stat().st_size > 65536:
        raise WorkerError("invalid_package", "Missing or oversized classifier.json")
    encoded = manifest_path.read_bytes()
    try:
        manifest = json.loads(encoded)
        if type(manifest["format_version"]) is not int or manifest["format_version"] != 1 or manifest["policy_version"] not in ("groundkeeper-18-v1", POLICY_VERSION):
            raise WorkerError("incompatible_policy", "Unsupported package format or policy")
        if manifest["backend"] not in ("qwen_mlx", "laya_mps"):
            raise WorkerError("invalid_package", "Unsupported local backend")
        files = manifest["files"]
        if not isinstance(files, dict) or not files or len(files) > 512:
            raise ValueError("files")
        total = len(encoded)
        for name, expected in files.items():
            _check(cancelled)
            path = _relative(root, name)
            if path.suffix in (".py", ".pyc", ".so", ".dylib", ".pickle", ".pkl", ".bin"):
                raise WorkerError("invalid_package", "Executable or pickle model content is forbidden")
            size = path.stat().st_size
            total += size
            if size != expected["bytes"] or total > MAX_PACKAGE_BYTES:
                raise WorkerError("invalid_package", "Package size mismatch or limit exceeded")
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                while chunk := stream.read(4 * 1024 * 1024):
                    _check(cancelled)
                    digest.update(chunk)
            if digest.hexdigest() != expected["sha256"]:
                raise WorkerError("invalid_package", "Package checksum mismatch")
        # Every loadable file must be verified; extra files must not influence loaders.
        actual = {str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()}
        if actual != set(files) | {"classifier.json"}:
            raise WorkerError("invalid_package", "Unexpected package files")
        if not isinstance(manifest["model_id"], str) or not manifest["model_id"]:
            raise ValueError("model_id")
        if manifest.get("prompt_version", "v1") not in ("v1", "v2"):
            raise ValueError("prompt_version")
        for field in ("model_directory", "adapter_directory"):
            if field not in manifest:
                continue
            value = manifest[field]
            directory = (root / value).resolve()
            if not isinstance(value, str) or Path(value).is_absolute() or not directory.is_relative_to(root) or not directory.is_dir():
                raise ValueError(field)
        return manifest, hashlib.sha256(encoded).hexdigest()
    except WorkerError:
        raise
    except (ValueError, TypeError, KeyError, OSError) as error:
        raise WorkerError("invalid_package", "Invalid model package manifest") from error


class Worker:
    def __init__(self):
        for key, value in {"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
                           "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false",
                           "USE_TF": "0", "PYTORCH_ENABLE_MPS_FALLBACK": "0"}.items():
            os.environ[key] = value
        self.model = self.tokenizer = self.grammar = self.manifest = self.identity = None
        self.root = None
        self._allocated_backend = None

    def handle(self, request, cancelled=lambda: False, event=lambda _: None, package_root=None):
        """Return one JSON-safe envelope. Exceptions never include financial inputs."""
        started = time.monotonic()
        request_id = request.get("request_id") if isinstance(request, dict) else None
        try:
            if not isinstance(request, dict) or type(request.get("protocol_version")) is not int or request.get("protocol_version") != PROTOCOL_VERSION:
                raise WorkerError("incompatible_protocol", "Unsupported protocol version")
            if not isinstance(request_id, str) or not 1 <= len(request_id) <= 128:
                raise WorkerError("invalid_request", "Invalid request ID")
            operation = request.get("operation")
            if operation not in ("handshake", "prepare_model", "prepare_shortcut", "classify", "release_model", "gpu_probe"):
                raise WorkerError("unsupported_operation", "Unsupported operation")
            _check(cancelled)
            if operation == "handshake":
                result = {"policy_version": POLICY_VERSION, "categories": list(CATEGORIES), "types": list(TYPES),
                          "backends": ["qwen_mlx", "laya_mps", "apple_shortcut"], "gpu_required": True,
                          "loaded_model": self.identity,
                          "runtime": {p: importlib.metadata.version(p) for p in ("mlx", "mlx-lm", "torch", "laya")}}
            elif operation == "gpu_probe":
                result = self.gpu_probe()
            elif operation == "release_model":
                self.release()
                result = {"released": True}
            elif operation == "prepare_shortcut":
                name = request.get("shortcut_name")
                if not isinstance(name, str) or not name.strip() or len(name) > 128 or any(ord(c) < 32 for c in name):
                    raise WorkerError("invalid_request", "Choose a valid Shortcut name")
                self.release()
                from .apple_shortcuts import AppleShortcutCategorizer
                self.model = AppleShortcutCategorizer(name)
                self.manifest = {"backend": "apple_shortcut"}
                digest = hashlib.sha256(json.dumps([POLICY_VERSION, "apple_shortcut", name, "receipt-context-v1", "wallet-category-hint-v1", "merchant-search-v1"]).encode()).hexdigest()
                self.identity = {"model_id": name, "backend": "apple_shortcut", "manifest_sha256": digest,
                                 "policy_version": POLICY_VERSION, "device": "shortcut"}
                result = {"model": self.identity}
            elif operation == "prepare_model":
                if package_root is None:
                    raise WorkerError("invalid_package", "A native-authorized package directory is required")
                event({"stage": "verifying_package"})
                root = Path(package_root).resolve()
                manifest, digest = verify_package(root, cancelled)
                if self.identity is not None and self.identity["manifest_sha256"] == digest:
                    result = {"model": self.identity, "reused": True}
                else:
                    self.release()
                    event({"stage": "loading_model"})
                    try:
                        self.prepare(root, manifest, digest)
                        _check(cancelled)
                    except BaseException as error:
                        # Failed loader frames can retain tensors until the exception
                        # is handled. Drop those references before clearing allocators.
                        _clear_exception_frames(error)
                        self.release()
                        raise
                    result = {"model": self.identity, "reused": False}
            else:
                result = self.classify(request, cancelled)
            _check(cancelled)
            return {"protocol_version": PROTOCOL_VERSION, "request_id": request_id, "status": "succeeded",
                    "elapsed_ms": round((time.monotonic() - started) * 1000, 3), "result": result}
        except WorkerError as error:
            code, message = error.code, error.message
        except (ValueError, TypeError, KeyError):
            code, message = "invalid_request", "Request does not match the classifier contract"
        except Exception:
            # No traceback or dependency exception text crosses the privacy boundary.
            code, message = "inference_failed", "Local inference failed"
        return {"protocol_version": PROTOCOL_VERSION, "request_id": request_id, "status": "failed",
                "error": {"code": code, "message": message}}

    def gpu_probe(self):
        import mlx.core as mx
        import torch
        if not mx.metal.is_available() or not torch.backends.mps.is_available():
            raise WorkerError("gpu_unavailable", "Metal GPU is required for local inference")
        with mx.stream(mx.gpu):
            a = mx.ones((32, 32))
            b = a @ a
            mx.eval(b)
            mlx_value = b[0, 0].item()
        with torch.inference_mode():
            a = torch.ones((32, 32), device="mps")
            b = a @ a
            torch.mps.synchronize()
            torch_value = b[0, 0].item()
        return {"mlx": {"device": "gpu", "metal_available": True, "value": mlx_value},
                "laya": {"device": str(b.device), "mps_available": True, "value": torch_value}}

    def prepare(self, root, manifest, digest):
        backend = manifest["backend"]
        if backend == "qwen_mlx":
            import mlx.core as mx
            if not mx.metal.is_available():
                raise WorkerError("gpu_unavailable", "MLX Metal GPU is unavailable")
            self._allocated_backend = backend
            mx.set_default_device(mx.gpu)
            # Bounded allocator cache; model weights remain quantized on unified memory.
            mx.set_cache_limit(128 * 1024 * 1024)
            mx.set_memory_limit(10 * 1024 * 1024 * 1024)
            from mlx_lm import load
            from .constraints import DecisionGrammar
            with mx.stream(mx.gpu):
                self.model, self.tokenizer = load(str(root / manifest.get("model_directory", "model")),
                    adapter_path=str(root / manifest["adapter_directory"]) if manifest.get("adapter_directory") else None,
                    tokenizer_config={"trust_remote_code": False})
                mx.eval(self.model.parameters())
            self.grammar = DecisionGrammar(self.tokenizer)
        else:
            import torch
            if not torch.backends.mps.is_available():
                raise WorkerError("gpu_unavailable", "PyTorch Metal MPS is unavailable")
            self._allocated_backend = backend
            torch.set_num_threads(2)
            from .laya_runtime import LocalLayaCategorizer
            self.model = LocalLayaCategorizer(root / manifest.get("model_directory", "."), device="mps")
        self.manifest, self.root = manifest, root
        self.identity = {"model_id": manifest["model_id"], "backend": backend, "manifest_sha256": digest,
                         "policy_version": POLICY_VERSION, "device": "mlx_gpu" if backend == "qwen_mlx" else "mps"}

    def classify(self, request, cancelled):
        if self.model is None:
            raise WorkerError("model_not_ready", "Prepare a model before classification")
        if request.get("policy_version") != POLICY_VERSION:
            raise WorkerError("incompatible_policy", "Unsupported classification policy")
        if request.get("model_manifest_sha256") != self.identity["manifest_sha256"]:
            raise WorkerError("model_mismatch", "Prepared model does not match request")
        for key in ("part_id", "job_id"):
            if not isinstance(request.get(key), str) or not 1 <= len(request[key]) <= 128:
                raise ValueError(key)
        if type(request.get("transaction_revision")) is not int or request["transaction_revision"] < 1:
            raise ValueError("transaction_revision")
        inputs = validate_input(request["input"])
        if len(inputs["description"]) > MAX_DESCRIPTION:
            raise WorkerError("input_too_large", "Description exceeds inference limit")
        _check(cancelled)
        if self.manifest["backend"] == "qwen_mlx":
            answer = self.qwen(inputs, cancelled)
        elif self.manifest["backend"] == "apple_shortcut":
            from .apple_shortcuts import ShortcutExecutionError
            try:
                answer = self.model.suggest(inputs, cancelled=cancelled)
            except ShortcutExecutionError as error:
                code = {"timeout": "deadline_exceeded", "cancelled": "cancelled",
                        "invalid_output": "invalid_output", "rate_limited": "shortcut_rate_limited"}.get(error.detail["status"], "shortcut_unavailable")
                raise WorkerError(code, "Apple Shortcut could not complete; check its configuration in Shortcuts") from None
        else:
            import torch
            with torch.inference_mode():
                answer, detail = self.model.predict(inputs)
                torch.mps.synchronize()
                if self.model.agent.device.type != "mps" or next(self.model.agent.model.parameters()).device.type != "mps":
                    raise WorkerError("gpu_unavailable", "Laya moved away from Metal MPS")
                if not detail["valid_schema"]:
                    raise WorkerError("invalid_output", "Laya output could not be validated")
        _check(cancelled)
        answer = validate_answer({**answer, "review": True})
        return {"decision": answer, "model": self.identity, "part_id": request["part_id"],
                "job_id": request["job_id"], "transaction_revision": request["transaction_revision"]}

    def qwen(self, inputs, cancelled):
        import mlx.core as mx
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler
        from .policy import messages, parse_answer
        from .policy_v2 import messages_v2
        builder = messages_v2 if self.manifest.get("prompt_version") == "v2" else messages
        prompt = self.tokenizer.apply_chat_template(builder(inputs), tokenize=True,
            add_generation_prompt=True, enable_thinking=False, return_dict=False)
        if "merchant_context" in inputs:
            from .merchant_context import shrink_web_evidence
            while len(prompt) > 3072 and "merchant_context" in inputs:
                inputs = shrink_web_evidence(inputs)
                prompt = self.tokenizer.apply_chat_template(builder(inputs), tokenize=True,
                    add_generation_prompt=True, enable_thinking=False, return_dict=False)
        if len(prompt) > (3072 if "merchant_context" in inputs else 3072 if "transaction_notes" in inputs else 2048 if "receipt_context" in inputs else 768 if "wallet_category_raw" in inputs else 512):
            raise WorkerError("input_too_large", "Tokenized input exceeds model context policy")
        chunks = []
        with mx.stream(mx.gpu):
            iterator = stream_generate(self.model, self.tokenizer, prompt=prompt,
                max_tokens=self.grammar.max_answer_tokens + 2, sampler=make_sampler(0),
                logits_processors=[self.grammar.processor(len(prompt))], prompt_progress_callback=lambda *_: _check(cancelled))
            try:
                for response in iterator:
                    _check(cancelled)
                    chunks.append(response.text)
            finally:
                iterator.close()
            mx.synchronize()
        text = "".join(chunks)
        if text not in self.grammar.answers:
            raise WorkerError("invalid_output", "Constrained output did not complete")
        return parse_answer(text)

    def release(self):
        backend = self._allocated_backend or (self.manifest["backend"] if self.manifest else None)
        self._allocated_backend = None
        self.model = self.tokenizer = self.grammar = self.manifest = self.identity = self.root = None
        gc.collect()
        if backend == "qwen_mlx":
            import mlx.core as mx
            mx.synchronize()
            mx.clear_cache()
        elif backend == "laya_mps":
            import torch
            torch.mps.synchronize()
            torch.mps.empty_cache()


# The native service initializes this exactly once on its inference thread.
_worker = None


def dispatch(encoded, package_root=None):
    import gk_native
    global _worker
    if _worker is None:
        _worker = Worker()
    try:
        request = json.loads(encoded)
    except (ValueError, TypeError):
        request = None
    return json.dumps(_worker.handle(request, gk_native.cancelled,
        lambda event: gk_native.event(json.dumps(event)), package_root), separators=(",", ":"), allow_nan=False)
