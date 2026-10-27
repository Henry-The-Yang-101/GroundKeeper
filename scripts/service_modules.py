"""Explicit shipping and experiment module boundaries for the Python package."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "contracts/classifier/service-modules.json"


def module_manifest():
    return json.loads(MANIFEST.read_text())


def service_files(service):
    if service not in ("classifier", "merchant_search"):
        raise ValueError(f"Unknown XPC service: {service}")
    return tuple(f"{name}.py" for name in module_manifest()[service])
