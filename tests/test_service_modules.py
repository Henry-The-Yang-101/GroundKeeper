"""The packaged services must contain their own complete Python import graph."""

import ast

import pytest

from scripts import embed_classifier_runtime
from scripts.service_modules import ROOT, module_manifest, service_files


def test_every_package_module_has_an_explicit_shipping_or_experiment_role():
    groups = module_manifest()
    shipped = set(groups["classifier"]) | set(groups["merchant_search"])
    experimental = set(groups["experiment"])
    assert shipped.isdisjoint(experimental)
    assert shipped | experimental == {path.stem for path in (ROOT / "groundkeeper").glob("*.py")}
    for service in ("classifier", "merchant_search"):
        available = set(groups[service])
        for name in available:
            tree = ast.parse((ROOT / "groundkeeper" / f"{name}.py").read_text())
            imports = {
                node.module.split(".")[0]
                for node in ast.walk(tree)
                if isinstance(node, ast.ImportFrom) and node.level == 1 and node.module
            }
            assert imports <= available, (service, name, imports - available)


@pytest.mark.parametrize(
    "service,target",
    [
        ("classifier", "GroundKeeperClassifier"),
        ("merchant_search", "GroundKeeperMerchantSearch"),
    ],
)
def test_embedding_copies_only_service_modules_and_removes_retired_code(
    tmp_path, monkeypatch, service, target
):
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    (runtime / "runtime-lock.json").write_text('{"format_version":2}')
    bundle = tmp_path / "bundle"
    worker = bundle / "Resources/Worker/groundkeeper"
    worker.mkdir(parents=True)
    (worker / "runtime.py").write_text("retired = True")
    monkeypatch.setattr(embed_classifier_runtime, "DEST", runtime)
    monkeypatch.setenv("TARGET_BUILD_DIR", str(tmp_path))
    monkeypatch.setenv("CONTENTS_FOLDER_PATH", "bundle")
    monkeypatch.setenv("TARGET_NAME", target)
    embed_classifier_runtime.main()
    assert {path.name for path in worker.glob("*.py")} == set(service_files(service))
    for path in worker.glob("*.py"):
        assert path.read_bytes() == (ROOT / "groundkeeper" / path.name).read_bytes()
