"""Package a selected continuation checkpoint against a verified app base package.

Does not read training/held-out examples or modify previous model packages.
"""

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

from groundkeeper.worker import verify_package


def export(base, run, destination, training_config):
    manifest, _ = verify_package(base.resolve(), lambda: False)
    if manifest["backend"] != "qwen_mlx" or destination.exists():
        raise ValueError("Expected a Qwen base and a new destination")
    selection = json.loads((run / "selection.json").read_text())["selected"]
    adapter = run / "selected-adapter/adapters.safetensors"
    if hashlib.sha256(adapter.read_bytes()).hexdigest() != selection["checkpoint_sha256"]:
        raise ValueError("Selected checkpoint integrity mismatch")
    config = json.loads(training_config.read_text())
    if manifest["files"]["model/model.safetensors"]["sha256"] != config["base_weight_sha256"]:
        raise ValueError("Continuation base weights do not match package")
    destination.mkdir(parents=True)
    try:
        for name in manifest["files"]:
            if name.startswith("adapters/"):
                continue
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["/bin/cp", "-c", str(base / name), str(target)], check=True)
        shutil.copytree(run / "selected-adapter", destination / "adapters")
        files = {}
        for path in destination.rglob("*"):
            if path.is_file():
                digest = hashlib.sha256()
                with path.open("rb") as stream:
                    while chunk := stream.read(4 * 1024 * 1024):
                        digest.update(chunk)
                files[str(path.relative_to(destination))] = {
                    "bytes": path.stat().st_size,
                    "sha256": digest.hexdigest(),
                }
        manifest.update(
            model_id=f"qwen-{run.name}-step{selection['step']}",
            prompt_version="v2",
            adapter_directory="adapters",
            files=files,
        )
        (destination / "classifier.json").write_text(json.dumps(manifest, indent=2) + "\n")
        verify_package(destination.resolve(), lambda: False)
    except BaseException:
        shutil.rmtree(destination)
        raise
    print(destination.resolve())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("base", type=Path)
    parser.add_argument("run", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--training-config", type=Path, required=True)
    args = parser.parse_args()
    export(args.base, args.run, args.destination, args.training_config)
