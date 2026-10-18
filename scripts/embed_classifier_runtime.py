"""Xcode build phase: embed and sign staged runtime plus current worker sources."""
import os
import hashlib
from pathlib import Path
import shutil
import subprocess

from scripts.prepare_classifier_runtime import DEST, ROOT, native


def main():
    if not (DEST / "runtime-lock.json").is_file():
        raise SystemExit("Run .venv/bin/python -m scripts.prepare_classifier_runtime before building the app")
    bundle = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["CONTENTS_FOLDER_PATH"]
    bundle.mkdir(parents=True, exist_ok=True)
    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
    cache_key = hashlib.sha256((DEST / "runtime-lock.json").read_bytes() + identity.encode()).hexdigest()
    marker = bundle / "Resources/runtime-embedding.txt"
    embed = not marker.is_file() or marker.read_text() != cache_key
    if embed:
        for folder in ("Frameworks", "Resources/Python"):
            target = bundle / folder
            target.mkdir(parents=True, exist_ok=True)
            subprocess.run(["/usr/bin/rsync", "-a", "--delete", str(DEST / folder) + "/", str(target) + "/"], check=True)
    worker = bundle / "Resources/Worker/groundkeeper"
    worker.mkdir(parents=True, exist_ok=True)
    for name in ("__init__.py", "worker.py", "policy.py", "policy_v2.py", "constraints.py", "laya_runtime.py", "apple_shortcuts.py"):
        shutil.copy2(ROOT / "groundkeeper" / name, worker / name)
    shutil.copy2(DEST / "runtime-lock.json", bundle / "Resources/runtime-lock.json")
    if embed:
        for directory in (bundle / "Frameworks", bundle / "Resources/Python"):
            for path in directory.rglob("*"):
                if native(path):
                    subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime", str(path)],
                                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        marker.write_text(cache_key)


if __name__ == "__main__":
    main()
