"""Embed each service's worker code; the host app owns the shared runtime."""
import os
from pathlib import Path
import shutil

from scripts.prepare_classifier_runtime import DEST, ROOT


def main():
    if not (DEST / "runtime-lock.json").is_file():
        raise SystemExit("Run .venv/bin/python -m scripts.prepare_classifier_runtime before building the app")
    bundle = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["CONTENTS_FOLDER_PATH"]
    bundle.mkdir(parents=True, exist_ok=True)
    # Runtime lives once in the enclosing app. Retire copies from older builds.
    for folder in ("Frameworks", "Resources/Python"):
        target = bundle / folder
        if target.exists():
            shutil.rmtree(target)
    marker = bundle / "Resources/runtime-embedding.txt"
    marker.unlink(missing_ok=True)
    worker = bundle / "Resources/Worker/groundkeeper"
    worker.mkdir(parents=True, exist_ok=True)
    names = ("__init__.py", "merchant_search.py", "merchant_context.py") if os.environ.get("TARGET_NAME") == "GroundKeeperMerchantSearch" else ("__init__.py", "worker.py", "policy.py", "policy_v2.py", "receipts.py", "constraints.py", "laya_runtime.py", "apple_shortcuts.py", "merchant_context.py")
    for existing in worker.glob("*.py"):
        if existing.name not in names:
            existing.unlink()
    for name in names:
        shutil.copy2(ROOT / "groundkeeper" / name, worker / name)
    shutil.copy2(DEST / "runtime-lock.json", bundle / "Resources/runtime-lock.json")


if __name__ == "__main__":
    main()
